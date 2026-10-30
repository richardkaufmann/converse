using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

var checks = new Checks();
var root = FindRepoRoot(args);
var contracts = Path.Combine(root, "linux", "contracts");
var schemasDir = Path.Combine(contracts, "schemas");
var examplesDir = Path.Combine(contracts, "examples");
var fakeSshDir = Path.Combine(contracts, "fake-ssh");
var invalidDir = Path.Combine(contracts, "invalid");
var validator = new SchemaValidator();

string[] expectedSchemas =
[
    "admin-request.schema.json",
    "admin-response.schema.json",
    "deployment-registry.schema.json",
    "operation.schema.json",
    "pairing-binding.schema.json",
    "recovery-ledger.schema.json",
    "release-manifest.schema.json",
    "secret-request.schema.json",
    "secret-response.schema.json",
    "status.schema.json",
];

var actualSchemas = Directory.GetFiles(schemasDir, "*.schema.json")
    .Select(Path.GetFileName)
    .OrderBy(name => name, StringComparer.Ordinal)
    .ToArray();
checks.That(actualSchemas.SequenceEqual(expectedSchemas), "schema set is frozen");

var schemaIDs = new HashSet<string>(StringComparer.Ordinal);
foreach (var file in expectedSchemas)
{
    using var schema = ReadJson(Path.Combine(schemasDir, file));
    checks.That(
        schema.RootElement.GetProperty("$schema").GetString() ==
        "https://json-schema.org/draft/2020-12/schema",
        $"{file} declares JSON Schema 2020-12");
    var id = schema.RootElement.GetProperty("$id").GetString() ?? "";
    checks.That(id.StartsWith("urn:converse:linux:", StringComparison.Ordinal) && schemaIDs.Add(id),
        $"{file} has a unique Converse Linux schema ID");
}

void ValidateExample(string example, string schema)
{
    using var document = ReadJson(Path.Combine(examplesDir, example));
    var errors = validator.ValidateFile(document.RootElement, Path.Combine(schemasDir, schema));
    checks.That(errors.Count == 0, $"{example} validates against {schema}", string.Join("; ", errors));
}

bool CounterWithinBound(JsonElement value) =>
    value.ValueKind == JsonValueKind.String &&
    ulong.TryParse(value.GetString(), out var parsed) && parsed <= (1UL << 53);

ulong Counter(JsonElement value) => ulong.Parse(value.GetString()!);

bool ValidStateRange(JsonElement manifest)
{
    var compatibility = manifest.GetProperty("protocols").GetProperty("stateSchemaCompatibility");
    var minimum = compatibility.GetProperty("minimumReadableStateSchemaVersion").GetInt32();
    var maximum = compatibility.GetProperty("maximumReadableStateSchemaVersion").GetInt32();
    var writable = compatibility.GetProperty("writableStateSchemaVersion").GetInt32();
    return minimum <= writable && writable <= maximum;
}

ValidateExample("admin-request-status.json", "admin-request.schema.json");
ValidateExample("admin-request-update-activate.json", "admin-request.schema.json");
ValidateExample("admin-request-pairing-confirm.json", "admin-request.schema.json");
ValidateExample("admin-request-session-create.json", "admin-request.schema.json");
ValidateExample("secret-request-header.json", "secret-request.schema.json");
ValidateExample("secret-response.json", "secret-response.schema.json");
ValidateExample("admin-response-operation.json", "admin-response.schema.json");
ValidateExample("status.json", "status.schema.json");
ValidateExample("operation.json", "operation.schema.json");
ValidateExample("pairing-binding.json", "pairing-binding.schema.json");
ValidateExample("release-manifest.json", "release-manifest.schema.json");
ValidateExample("deployment-registry.json", "deployment-registry.schema.json");
ValidateExample("recovery-ledger.json", "recovery-ledger.schema.json");

using var statusDoc = ReadJson(Path.Combine(examplesDir, "status.json"));
var status = statusDoc.RootElement;
var episode = status.GetProperty("release").GetProperty("updateEpisode");
checks.That(
    episode.GetProperty("phase").GetString() == "probation_new_release" &&
    episode.GetProperty("explicitResolutionRequired").GetBoolean() &&
    status.GetProperty("runtime").GetProperty("admission").GetString() == "closed_probation",
    "probation remains admission-closed until explicit resolution");
checks.That(
    status.GetProperty("secrets").EnumerateArray().All(secret =>
        !secret.TryGetProperty("value", out _) && !secret.TryGetProperty("fingerprint", out _) &&
        secret.GetProperty("backend").GetString() == "linux-file-0600" &&
        secret.GetProperty("storedVersion").GetInt32() == 0 &&
        secret.GetProperty("effectiveVersion").GetInt32() == 0 &&
        !secret.GetProperty("pendingRestart").GetBoolean()),
    "status exposes versioned secret metadata only");

using var ledgerDoc = ReadJson(Path.Combine(examplesDir, "recovery-ledger.json"));
var ledger = ledgerDoc.RootElement;
checks.That(
    ledger.GetProperty("commandReceipts").EnumerateArray()
        .Any(receipt => receipt.GetProperty("state").GetString() == "uncertain" &&
                        receipt.GetProperty("terminalAt").ValueKind == JsonValueKind.Null),
    "recovery ledger preserves nonterminal uncertain command evidence");
checks.That(
    ledger.GetProperty("operations").EnumerateArray()
        .Any(operation => operation.GetProperty("state").GetString() == "probation_new_release" &&
                          operation.GetProperty("terminalAt").ValueKind == JsonValueKind.Null),
    "recovery ledger preserves nonterminal probation operation evidence");
var restoration = ledger.GetProperty("displayRestorations")[0];
checks.That(
    restoration.GetProperty("lastAuthorizedOwnerDeviceID").GetString()?.Length == 64 &&
    Counter(restoration.GetProperty("takeGeneration")) > 0 &&
    Counter(restoration.GetProperty("lastExecutionEpoch")) <
    Counter(ledger.GetProperty("counterFloors").GetProperty("nextLeaseEpoch")),
    "display restoration is separated from fresh execution epochs");
checks.That(
    ledger.GetProperty("membership").GetProperty("removedDeviceIDs").GetArrayLength() == 1 &&
    ledger.GetProperty("dissolvedGroupIDs").GetArrayLength() == 1,
    "recovery ledger retains membership and dissolution tombstones");

using var registryDoc = ReadJson(Path.Combine(examplesDir, "deployment-registry.json"));
var forbiddenRegistryKeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
{
    "password", "passphrase", "privateKey", "secret", "value", "verificationCode",
    "transcript", "draft", "apiKey", "webhookURL",
};
checks.That(!ContainsAnyKey(registryDoc.RootElement, forbiddenRegistryKeys),
    "deployment registry carries no credential or conversation fields");
var registryRemote = registryDoc.RootElement.GetProperty("deployments")[0].GetProperty("remote");
var statusFilesystem = status.GetProperty("filesystem");
checks.That(
    registryRemote.GetProperty("installRoot").GetString() ==
    statusFilesystem.GetProperty("installRoot").GetString() &&
    registryRemote.GetProperty("stateRoot").GetString() ==
    statusFilesystem.GetProperty("stateRoot").GetString(),
    "deployment registry roots bind to daemon-reported filesystem status");
var provisional = registryDoc.RootElement.GetProperty("provisionalDeployments")[0];
checks.That(
    provisional.GetProperty("operationID").GetString()?.Length == 36 &&
    provisional.GetProperty("stagingToken").GetString()?.Length == 32 &&
    provisional.GetProperty("stage").GetString() == "uploaded",
    "deployment registry preserves provisional bootstrap operation ownership");

using var pairingDoc = ReadJson(Path.Combine(examplesDir, "pairing-binding.json"));
var code = pairingDoc.RootElement.GetProperty("verificationCode").GetString() ?? "";
checks.That(code.Split(' ').Length == 8 && code.Replace(" ", "").Length == 32,
    "pairing example retains all eight verification-code groups");
var pairing = pairingDoc.RootElement;
var codeFingerprint = Convert.ToHexString(
    SHA256.HashData(Encoding.ASCII.GetBytes(code.Replace(" ", "")))).ToLowerInvariant();
checks.That(
    pairing.GetProperty("verificationCodeFingerprint").GetString() == codeFingerprint &&
    pairing.GetProperty("requesterConnectionInstanceID").GetString()?.Length == 36 &&
    pairing.GetProperty("sponsorConnectionInstanceID").GetString() ==
        pairing.GetProperty("nativeRequestID").GetString() &&
    pairing.GetProperty("linuxPublicKeyFingerprint").GetString() ==
        pairing.GetProperty("linuxDeviceID").GetString() &&
    pairing.GetProperty("sponsorPublicKeyFingerprint").GetString() ==
        pairing.GetProperty("sponsorDeviceID").GetString() &&
    pairing.GetProperty("expiresAt").ValueKind == JsonValueKind.String,
    "pairing binding carries request, key, connection, code-fingerprint, and expiry identity");

using var manifestDoc = ReadJson(Path.Combine(examplesDir, "release-manifest.json"));
checks.That(ValidStateRange(manifestDoc.RootElement),
    "release manifest example has a coherent readable/writable state range");
using var invalidManifest = ReadJson(Path.Combine(invalidDir, "release-manifest-state-range.json"));
checks.That(!ValidStateRange(invalidManifest.RootElement),
    "negative fixture rejects an impossible release state range");
using var numericCounter = ReadJson(Path.Combine(invalidDir, "recovery-ledger-counter-number.json"));
checks.That(validator.ValidateFile(
        numericCounter.RootElement,
        Path.Combine(schemasDir, "recovery-ledger.schema.json")).Count > 0,
    "negative fixture rejects numeric recovery counters");
using var overflowCounter = ReadJson(Path.Combine(invalidDir, "recovery-ledger-counter-overflow.json"));
checks.That(
    !CounterWithinBound(overflowCounter.RootElement.GetProperty("sequence")) &&
    !CounterWithinBound(overflowCounter.RootElement
        .GetProperty("counterFloors").GetProperty("nextHomeSeq")),
    "negative fixture rejects counters above the 2^53 bound");
checks.That(
    CounterWithinBound(ledger.GetProperty("membership")
        .GetProperty("generationFloors")
        .GetProperty("3333333333333333333333333333333333333333333333333333333333333333")),
    "recovery ledger example preserves the exact 2^53 high-water mark");

string[] expectedCases =
[
    "auth-failed",
    "daemon-unavailable",
    "disconnect-after-accept",
    "host-key-changed",
    "identity-mismatch",
    "offline-status-stopped",
    "secret-stdin-ok",
    "status-ok",
    "trust-captured-auth-expected",
];
var actualCases = Directory.GetDirectories(fakeSshDir)
    .Select(Path.GetFileName)
    .OrderBy(name => name, StringComparer.Ordinal)
    .ToArray();
checks.That(actualCases.SequenceEqual(expectedCases), "fake-SSH case set is frozen");

string[] automatedArgv =
[
    "ssh",
    "-o", "BatchMode=yes",
    "-o", "StrictHostKeyChecking=yes",
    "-o", "RequestTTY=no",
    "-o", "ForwardAgent=no",
    "-o", "ForwardX11=no",
    "-o", "ClearAllForwardings=yes",
    "-o", "ConnectTimeout=10",
    "-o", "ServerAliveInterval=5",
    "-o", "ServerAliveCountMax=2",
    "--",
    "linux-home",
    "exec \"$HOME/.local/bin/converse\" admin-request",
];

foreach (var caseName in expectedCases)
{
    var caseDir = Path.Combine(fakeSshDir, caseName);
    using var caseDoc = ReadJson(Path.Combine(caseDir, "case.json"));
    var testCase = caseDoc.RootElement;
    var argv = testCase.GetProperty("argv").EnumerateArray()
        .Select(value => value.GetString() ?? "")
        .ToArray();
    var combined = string.Join("\n", argv);
    checks.That(!combined.Contains("accept-new", StringComparison.Ordinal),
        $"{caseName} never uses accept-new");
    checks.That(!argv.Any(argument =>
            argument.Contains("sshpass", StringComparison.OrdinalIgnoreCase) ||
            (argument.Contains("password", StringComparison.OrdinalIgnoreCase) &&
             argument != "PasswordAuthentication=no")),
        $"{caseName} carries no password credential argument");

    var expected = testCase.GetProperty("expected");
    var classification = expected.GetProperty("classification").GetString();
    var stderrName = testCase.GetProperty("stderrFile").GetString() ?? "";
    var stderr = File.ReadAllText(Path.Combine(caseDir, stderrName));
    var stdoutName = testCase.GetProperty("stdoutFile").GetString() ?? "";
    var stdout = File.ReadAllText(Path.Combine(caseDir, stdoutName));

    if (caseName == "trust-captured-auth-expected")
    {
        checks.That(testCase.GetProperty("automation").GetString() == "manual_gate_required",
            "host-key trust transcript is explicitly not fake-automation proof");
        checks.That(argv.Contains("BatchMode=no") && argv.Contains("StrictHostKeyChecking=ask") &&
                    argv.Contains("RequestTTY=no") &&
                    argv[^1] == "true" && testCase.GetProperty("exitCode").GetInt32() == 255 &&
                    classification == "trust_captured_verify_then_strict_preflight",
            "trust-only expected auth failure leads to strict preflight");
        continue;
    }

    if (caseName == "secret-stdin-ok")
    {
        checks.That(argv[..^1].SequenceEqual(automatedArgv[..^1]) &&
                    argv[^1] == "exec \"$HOME/.local/bin/converse\" secret-stdin",
            "secret fixture uses the dedicated secret-stdin remote command");
        var stdinBytes = File.ReadAllBytes(Path.Combine(caseDir, "stdin.bin"));
        var newline = Array.IndexOf(stdinBytes, (byte)'\n');
        using var header = JsonDocument.Parse(Encoding.UTF8.GetString(stdinBytes, 0, newline));
        var headerErrors = validator.ValidateFile(
            header.RootElement, Path.Combine(schemasDir, "secret-request.schema.json"));
        var raw = stdinBytes[(newline + 1)..];
        var rawHash = Convert.ToHexString(SHA256.HashData(raw)).ToLowerInvariant();
        using var secretResponse = JsonDocument.Parse(stdout);
        var secretErrors = validator.ValidateFile(
            secretResponse.RootElement, Path.Combine(schemasDir, "secret-response.schema.json"));
        checks.That(headerErrors.Count == 0 && secretErrors.Count == 0 &&
                    raw.Length == header.RootElement.GetProperty("valueByteCount").GetInt32() &&
                    rawHash == header.RootElement.GetProperty("valueSHA256").GetString() &&
                    !stdout.Contains("fixture-secret-value", StringComparison.Ordinal),
            "secret fixture separates its header/raw value and returns only a metadata receipt");
        continue;
    }

    if (caseName == "offline-status-stopped")
    {
        checks.That(argv[..^1].SequenceEqual(automatedArgv[..^1]) &&
                    argv[^1] == "exec \"$HOME/.local/bin/converse\" offline-status",
            "offline fixture uses the fixed offline-status remote command");
        using var offline = JsonDocument.Parse(stdout);
        var offlineErrors = validator.ValidateFile(
            offline.RootElement, Path.Combine(schemasDir, "status.schema.json"));
        checks.That(offlineErrors.Count == 0 &&
                    offline.RootElement.GetProperty("runtime").GetProperty("processState").GetString() == "stopped" &&
                    !offline.RootElement.GetProperty("runtime").GetProperty("desiredRunning").GetBoolean(),
            "offline status identifies a stopped daemon without a live socket");
        continue;
    }

    checks.That(argv.SequenceEqual(automatedArgv), $"{caseName} uses the exact automated SSH argv");
    var stdinName = testCase.GetProperty("stdinFile").GetString() ?? "";
    var stdinPath = Path.Combine(caseDir, stdinName);
    var stdin = File.ReadAllText(stdinPath);
    checks.That(Encoding.UTF8.GetByteCount(stdin) <= 64 * 1024 && OneJsonLine(stdin),
        $"{caseName} stdin is one bounded JSON line");
    using var requestDoc = JsonDocument.Parse(stdin);
    var requestErrors = validator.ValidateFile(
        requestDoc.RootElement, Path.Combine(schemasDir, "admin-request.schema.json"));
    checks.That(requestErrors.Count == 0, $"{caseName} stdin validates as an admin request",
        string.Join("; ", requestErrors));

    if (expected.GetProperty("validAdminEnvelope").GetBoolean())
    {
        checks.That(Encoding.UTF8.GetByteCount(stdout) <= 1024 * 1024 && OneJsonLine(stdout),
            $"{caseName} stdout is one bounded JSON line");
        using var responseDoc = JsonDocument.Parse(stdout);
        var response = responseDoc.RootElement;
        var responseErrors = validator.ValidateFile(
            response, Path.Combine(schemasDir, "admin-response.schema.json"));
        checks.That(responseErrors.Count == 0, $"{caseName} stdout validates as an admin response",
            string.Join("; ", responseErrors));
        checks.That(
            response.GetProperty("requestID").GetString() ==
            requestDoc.RootElement.GetProperty("requestID").GetString(),
            $"{caseName} response binds the request ID");
        var expectedOK = expected.GetProperty("adminOk").GetBoolean();
        checks.That(response.GetProperty("ok").GetBoolean() == expectedOK,
            $"{caseName} response ok flag matches expectation");
        if (!expectedOK)
        {
            checks.That(
                response.GetProperty("error").GetProperty("code").GetString() ==
                expected.GetProperty("errorCode").GetString(),
                $"{caseName} response error code matches expectation");
        }
    }
    else
    {
        checks.That(string.IsNullOrWhiteSpace(stdout), $"{caseName} has no inferred admin response");
    }

    if (caseName == "status-ok")
    {
        using var responseDoc = JsonDocument.Parse(stdout);
        var result = responseDoc.RootElement.GetProperty("result");
        checks.That(Canonical(result) == Canonical(status),
            "status-ok fixture result exactly matches the status example");
        checks.That(
            result.GetProperty("device").GetProperty("deviceID").GetString() ==
            requestDoc.RootElement.GetProperty("expectedDeviceID").GetString(),
            "status-ok fixture binds the expected Converse identity");
    }
    if (caseName == "daemon-unavailable")
    {
        checks.That(testCase.GetProperty("exitCode").GetInt32() == 70,
            "daemon-unavailable keeps the frozen local CLI exit code");
    }
    if (caseName == "host-key-changed")
    {
        checks.That(stderr.Contains("REMOTE HOST IDENTIFICATION HAS CHANGED", StringComparison.Ordinal),
            "host-key fixture contains the OpenSSH changed-key signal");
    }
    if (caseName == "auth-failed")
    {
        checks.That(stderr.Contains("Permission denied", StringComparison.Ordinal),
            "auth fixture contains the OpenSSH permission signal");
    }
    if (caseName == "disconnect-after-accept")
    {
        using var operationDoc = ReadJson(Path.Combine(examplesDir, "operation.json"));
        checks.That(
            testCase.GetProperty("requestMayHaveBeenAccepted").GetBoolean() &&
            requestDoc.RootElement.GetProperty("operationID").GetString() ==
            operationDoc.RootElement.GetProperty("operationID").GetString() &&
            expected.GetProperty("nextAction").GetString() == "operation_get_with_same_operation_id",
            "disconnect after accept reconciles with the same operation ID");
    }
}

return checks.Finish();

static string FindRepoRoot(string[] args)
{
    if (args.Length > 0) return Path.GetFullPath(args[0]);
    var fromEnvironment = Environment.GetEnvironmentVariable("CONVERSE_REPO_ROOT");
    if (!string.IsNullOrWhiteSpace(fromEnvironment)) return Path.GetFullPath(fromEnvironment);
    var current = new DirectoryInfo(AppContext.BaseDirectory);
    while (current is not null)
    {
        if (File.Exists(Path.Combine(current.FullName, "VERSION.json")) &&
            Directory.Exists(Path.Combine(current.FullName, "linux", "contracts")))
            return current.FullName;
        current = current.Parent;
    }
    throw new DirectoryNotFoundException("Could not find the Converse repository root.");
}

static JsonDocument ReadJson(string path) => JsonDocument.Parse(File.ReadAllText(path));

static bool OneJsonLine(string text)
{
    var trimmed = text.Trim('\r', '\n');
    return trimmed.Length > 0 && !trimmed.Contains('\n') && !trimmed.Contains('\r');
}

static bool ContainsAnyKey(JsonElement value, HashSet<string> forbidden)
{
    if (value.ValueKind == JsonValueKind.Object)
    {
        foreach (var property in value.EnumerateObject())
        {
            if (forbidden.Contains(property.Name) || ContainsAnyKey(property.Value, forbidden))
                return true;
        }
    }
    if (value.ValueKind == JsonValueKind.Array)
        return value.EnumerateArray().Any(item => ContainsAnyKey(item, forbidden));
    return false;
}

static string Canonical(JsonElement value)
{
    using var stream = new MemoryStream();
    using (var writer = new Utf8JsonWriter(stream))
        WriteCanonical(writer, value);
    return Encoding.UTF8.GetString(stream.ToArray());
}

static void WriteCanonical(Utf8JsonWriter writer, JsonElement value)
{
    switch (value.ValueKind)
    {
        case JsonValueKind.Object:
            writer.WriteStartObject();
            foreach (var property in value.EnumerateObject().OrderBy(p => p.Name, StringComparer.Ordinal))
            {
                writer.WritePropertyName(property.Name);
                WriteCanonical(writer, property.Value);
            }
            writer.WriteEndObject();
            break;
        case JsonValueKind.Array:
            writer.WriteStartArray();
            foreach (var item in value.EnumerateArray()) WriteCanonical(writer, item);
            writer.WriteEndArray();
            break;
        default:
            value.WriteTo(writer);
            break;
    }
}

sealed class Checks
{
    private int _passed;
    private int _failed;

    public void That(bool condition, string name, string detail = "")
    {
        if (condition)
        {
            _passed++;
            Console.WriteLine($"PASS {name}");
        }
        else
        {
            _failed++;
            Console.WriteLine(detail.Length == 0 ? $"FAIL {name}" : $"FAIL {name}: {detail}");
        }
    }

    public int Finish()
    {
        Console.WriteLine($"{_passed} passed, {_failed} failed");
        return _failed == 0 ? 0 : 1;
    }
}

// Deliberately small JSON Schema subset covering only the frozen contract
// files. It fails on the constructs those files use rather than depending on
// a third-party validator just to keep examples honest.
sealed class SchemaValidator
{
    private readonly Dictionary<string, JsonDocument> _documents = new(StringComparer.Ordinal);

    public List<string> ValidateFile(JsonElement value, string schemaPath)
    {
        var fullPath = Path.GetFullPath(schemaPath);
        var schema = Load(fullPath).RootElement;
        var errors = new List<string>();
        Validate(value, schema, schema, fullPath, "$", errors);
        return errors;
    }

    private JsonDocument Load(string path)
    {
        if (!_documents.TryGetValue(path, out var document))
        {
            document = JsonDocument.Parse(File.ReadAllText(path));
            _documents[path] = document;
        }
        return document;
    }

    private void Validate(
        JsonElement value,
        JsonElement schema,
        JsonElement root,
        string schemaFile,
        string path,
        List<string> errors)
    {
        if (schema.ValueKind != JsonValueKind.Object) return;

        if (schema.TryGetProperty("$ref", out var reference))
        {
            var target = ResolveReference(reference.GetString() ?? "", root, schemaFile,
                out var targetRoot, out var targetFile);
            Validate(value, target, targetRoot, targetFile, path, errors);
        }
        if (schema.TryGetProperty("allOf", out var allOf))
        {
            foreach (var child in allOf.EnumerateArray())
                Validate(value, child, root, schemaFile, path, errors);
        }
        if (schema.TryGetProperty("anyOf", out var anyOf) &&
            !anyOf.EnumerateArray().Any(child => Matches(value, child, root, schemaFile)))
            errors.Add($"{path}: does not match anyOf");
        if (schema.TryGetProperty("oneOf", out var oneOf))
        {
            var matches = oneOf.EnumerateArray()
                .Count(child => Matches(value, child, root, schemaFile));
            if (matches != 1) errors.Add($"{path}: matches {matches} oneOf branches, expected 1");
        }
        if (schema.TryGetProperty("not", out var not) && Matches(value, not, root, schemaFile))
            errors.Add($"{path}: matches a forbidden schema");
        if (schema.TryGetProperty("if", out var condition) &&
            Matches(value, condition, root, schemaFile) &&
            schema.TryGetProperty("then", out var then))
            Validate(value, then, root, schemaFile, path, errors);

        if (schema.TryGetProperty("const", out var constant) && Canonical(value) != Canonical(constant))
            errors.Add($"{path}: expected constant {constant}");
        if (schema.TryGetProperty("enum", out var choices) &&
            !choices.EnumerateArray().Any(choice => Canonical(choice) == Canonical(value)))
            errors.Add($"{path}: value is not in enum");
        if (schema.TryGetProperty("type", out var type))
            ValidateType(value, type, path, errors);

        if (value.ValueKind == JsonValueKind.String)
            ValidateString(value.GetString() ?? "", schema, path, errors);
        if (value.ValueKind == JsonValueKind.Number)
            ValidateNumber(value, schema, path, errors);
        if (value.ValueKind == JsonValueKind.Array)
            ValidateArray(value, schema, root, schemaFile, path, errors);
        if (value.ValueKind == JsonValueKind.Object)
            ValidateObject(value, schema, root, schemaFile, path, errors);
    }

    private bool Matches(JsonElement value, JsonElement schema, JsonElement root, string schemaFile)
    {
        var errors = new List<string>();
        Validate(value, schema, root, schemaFile, "$", errors);
        return errors.Count == 0;
    }

    private JsonElement ResolveReference(
        string reference,
        JsonElement root,
        string schemaFile,
        out JsonElement targetRoot,
        out string targetFile)
    {
        if (reference.StartsWith("#/", StringComparison.Ordinal))
        {
            targetRoot = root;
            targetFile = schemaFile;
            var current = root;
            foreach (var rawPart in reference[2..].Split('/'))
            {
                var part = rawPart.Replace("~1", "/").Replace("~0", "~");
                current = current.GetProperty(part);
            }
            return current;
        }

        targetFile = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(schemaFile)!, reference));
        targetRoot = Load(targetFile).RootElement;
        return targetRoot;
    }

    private static void ValidateType(JsonElement value, JsonElement type, string path, List<string> errors)
    {
        var expected = type.GetString() ?? "";
        var matches = expected switch
        {
            "object" => value.ValueKind == JsonValueKind.Object,
            "array" => value.ValueKind == JsonValueKind.Array,
            "string" => value.ValueKind == JsonValueKind.String,
            "integer" => value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out _),
            "number" => value.ValueKind == JsonValueKind.Number,
            "boolean" => value.ValueKind is JsonValueKind.True or JsonValueKind.False,
            "null" => value.ValueKind == JsonValueKind.Null,
            _ => true,
        };
        if (!matches) errors.Add($"{path}: expected {expected}, got {value.ValueKind}");
    }

    private static void ValidateString(string value, JsonElement schema, string path, List<string> errors)
    {
        if (schema.TryGetProperty("minLength", out var min) && value.Length < min.GetInt32())
            errors.Add($"{path}: shorter than minLength {min}");
        if (schema.TryGetProperty("maxLength", out var max) && value.Length > max.GetInt32())
            errors.Add($"{path}: longer than maxLength {max}");
        if (schema.TryGetProperty("pattern", out var pattern) &&
            !Regex.IsMatch(value, pattern.GetString() ?? ""))
            errors.Add($"{path}: does not match pattern {pattern}");
        if (schema.TryGetProperty("format", out var format) && format.GetString() == "date-time" &&
            !IsDateTime(value))
            errors.Add($"{path}: is not an RFC 3339 date-time");
    }

    private static bool IsDateTime(string value) =>
        value.Contains('T') &&
        DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal, out _);

    private static void ValidateNumber(JsonElement value, JsonElement schema, string path, List<string> errors)
    {
        if (!value.TryGetDecimal(out var number)) return;
        if (schema.TryGetProperty("minimum", out var min) && number < min.GetDecimal())
            errors.Add($"{path}: below minimum {min}");
        if (schema.TryGetProperty("maximum", out var max) && number > max.GetDecimal())
            errors.Add($"{path}: above maximum {max}");
    }

    private void ValidateArray(
        JsonElement value,
        JsonElement schema,
        JsonElement root,
        string schemaFile,
        string path,
        List<string> errors)
    {
        if (schema.TryGetProperty("maxItems", out var max) && value.GetArrayLength() > max.GetInt32())
            errors.Add($"{path}: exceeds maxItems {max}");
        if (schema.TryGetProperty("uniqueItems", out var unique) && unique.GetBoolean())
        {
            var seen = new HashSet<string>(StringComparer.Ordinal);
            if (value.EnumerateArray().Any(item => !seen.Add(Canonical(item))))
                errors.Add($"{path}: contains duplicate items");
        }
        if (!schema.TryGetProperty("items", out var items)) return;
        var index = 0;
        foreach (var item in value.EnumerateArray())
            Validate(item, items, root, schemaFile, $"{path}[{index++}]", errors);
    }

    private void ValidateObject(
        JsonElement value,
        JsonElement schema,
        JsonElement root,
        string schemaFile,
        string path,
        List<string> errors)
    {
        if (schema.TryGetProperty("required", out var required))
        {
            foreach (var nameElement in required.EnumerateArray())
            {
                var name = nameElement.GetString() ?? "";
                if (!value.TryGetProperty(name, out _))
                    errors.Add($"{path}: missing required property {name}");
            }
        }

        var declared = new HashSet<string>(StringComparer.Ordinal);
        if (schema.TryGetProperty("properties", out var properties))
        {
            foreach (var property in properties.EnumerateObject())
            {
                declared.Add(property.Name);
                if (value.TryGetProperty(property.Name, out var child))
                    Validate(child, property.Value, root, schemaFile, $"{path}.{property.Name}", errors);
            }
        }

        if (schema.TryGetProperty("propertyNames", out var propertyNames))
        {
            foreach (var property in value.EnumerateObject())
            {
                using var nameDocument = JsonDocument.Parse(JsonSerializer.Serialize(property.Name));
                var nameErrors = new List<string>();
                Validate(nameDocument.RootElement, propertyNames, root, schemaFile, path, nameErrors);
                if (nameErrors.Count != 0)
                    errors.Add($"{path}: invalid property name {property.Name}");
            }
        }

        if (schema.TryGetProperty("additionalProperties", out var additional) &&
            additional.ValueKind == JsonValueKind.Object)
        {
            foreach (var property in value.EnumerateObject())
            {
                if (!declared.Contains(property.Name))
                    Validate(property.Value, additional, root, schemaFile,
                        $"{path}.{property.Name}", errors);
            }
        }
    }

    private static string Canonical(JsonElement value)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
            WriteCanonical(writer, value);
        return Encoding.UTF8.GetString(stream.ToArray());
    }

    private static void WriteCanonical(Utf8JsonWriter writer, JsonElement value)
    {
        switch (value.ValueKind)
        {
            case JsonValueKind.Object:
                writer.WriteStartObject();
                foreach (var property in value.EnumerateObject().OrderBy(p => p.Name, StringComparer.Ordinal))
                {
                    writer.WritePropertyName(property.Name);
                    WriteCanonical(writer, property.Value);
                }
                writer.WriteEndObject();
                break;
            case JsonValueKind.Array:
                writer.WriteStartArray();
                foreach (var item in value.EnumerateArray()) WriteCanonical(writer, item);
                writer.WriteEndArray();
                break;
            default:
                value.WriteTo(writer);
                break;
        }
    }
}
