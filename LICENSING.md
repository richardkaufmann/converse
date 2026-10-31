# Converse licensing

Copyright (C) 2026 Richard Kaufmann.

Except for the separately licensed components identified below, Converse is
free software: you can redistribute it and/or modify it under the terms of the
GNU General Public License as published by the Free Software Foundation,
either version 3 of the License, or (at your option) any later version
(`GPL-3.0-or-later`), with the additional permission below.

Converse is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
A PARTICULAR PURPOSE. See the GNU General Public License in `LICENSE` for details.

## Additional permission under GNU GPL version 3 section 7: SAM mask codec

If you modify Converse, or any covered work, by linking or combining it with
the SAM mask codec in `Sources/SAMMask.swift` (or a modified version of that
codec), containing parts covered by the terms of the SAM License, the copyright
holder of Converse grants you additional permission to convey the resulting
work. This permission applies only to that codec, adapted from Meta's
`meta-sam` parser (`mask-codec.ts`, revision
`9348a8a791d3e5b6417232227e32e10464cdf49f`). It is not a general exception for
other proprietary software or other SAM components.

Corresponding Source for a non-source form of such a combination shall include
the source code for the codec used as well as that for the covered work.
The codec remains subject to the SAM License, reproduced unchanged in
`Resources/ThirdParty/SAM-LICENSE.txt` (bundled as `ThirdParty/SAM-LICENSE.txt`
in Mac and iOS apps). This permission does not relicense Meta's code or waive
any obligation under that license. The SAM License's restrictions are not
additional restrictions on Converse's separately licensed GPL code.

As provided by GPL section 7, you may remove this additional permission from a
copy or from any part of it. Without this permission, do not convey a combined
work containing the incompatible SAM-licensed codec under plain GPL terms.

## Separately licensed components

- `Sources/SAMMask.swift`: codec adapted from Meta Platforms, Inc. and affiliates;
  distributed under the SAM License identified above, not relicensed as GPL.
- Provider logos: CC0 material from Simple Icons, with the existing license,
  attribution and trademark notices in `Resources/ProviderLogos/` retained.
  Trademark rights are not granted by Converse's license.
- External dependencies, operating-system frameworks and SDKs retain their own
  licenses. This change does not relicense them or grant rights to their marks.

The SAM exception is permission from Converse's copyright holder, not a claim
that Meta's SAM License is an open-source license. A package that includes the
codec therefore contains both GPL-covered and separately licensed material.

## Earlier versions and other distribution terms

This change applies to this revision and subsequent revisions carrying this
notice. It does not revoke Apache-2.0 permissions already granted for earlier
versions. Third-party notices and licenses must be preserved when applicable.

GPL permits charging for copies and distributing commercial forks, subject to
its terms. It does not prohibit commercial competition. Separate App Store or
other distribution terms require rights to all affected components; this notice
does not itself grant an App Store exception or relicense third-party code.
