using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

namespace Converse.App;

// A fixed sidebar column, including for homes that have not reported a provider.
public sealed class ProviderIcon : Grid
{
    public static readonly DependencyProperty EngineProperty = DependencyProperty.Register(
        nameof(Engine), typeof(string), typeof(ProviderIcon), new PropertyMetadata("", (d, _) => ((ProviderIcon)d).Render()));
    public string Engine { get => (string)GetValue(EngineProperty); set => SetValue(EngineProperty, value); }
    private readonly Image _image = new() { Stretch = Stretch.Uniform };
    private readonly TextBlock _fallback = new() { FontSize = 14, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };

    public ProviderIcon()
    {
        Width = Height = 20;
        Children.Add(_image); Children.Add(_fallback);
        Loaded += (_, _) => Render();
        ActualThemeChanged += (_, _) => Render();
    }

    private void Render()
    {
        var key = (Engine ?? "").ToLowerInvariant();
        var (asset, label) = key switch
        {
            "agent" or "muse" => ("meta", "Meta"),
            "claude" => ("anthropic", "Anthropic"),
            "codex" => (ActualTheme == ElementTheme.Dark ? "openai-dark" : "openai", "OpenAI"),
            _ => ("", key.Length == 0 ? "Provider not reported" : (Engine ?? ""))
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, label);
        var path = Path.Combine(AppContext.BaseDirectory, "Assets", "ProviderLogos", asset + ".png");
        var available = asset.Length > 0 && File.Exists(path);
        _image.Visibility = available ? Visibility.Visible : Visibility.Collapsed;
        _fallback.Visibility = available || key.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        _fallback.Text = label.Length > 0 ? label[..1] : "";
        _image.Source = available ? new BitmapImage(new Uri(path)) : null;
    }
}
