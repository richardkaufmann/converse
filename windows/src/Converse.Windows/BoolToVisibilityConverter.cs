using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Media;

namespace Converse.App;

// WinUI 3 ships no BooleanToVisibilityConverter (that type is WPF), so the
// shell carries this ten-line equivalent for button visibility bindings.
public sealed class BoolToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => value is true ? Visibility.Visible : Visibility.Collapsed;

    public object ConvertBack(object value, Type targetType, object parameter, string language)
        => value is Visibility.Visible;
}

// Mac PaneButton parity: the active P/1/2/3 button prints white on the Mac
// green; inactive buttons fall back to the theme default (UnsetValue).
// XAML has no DataTriggers, so the sidebar binds through these.
public sealed class ActiveToBackgroundConverter : IValueConverter
{
    private static readonly SolidColorBrush Green =
        new(Windows.UI.Color.FromArgb(255, 31, 133, 71));

    public object Convert(object value, Type targetType, object parameter, string language)
        => value is true ? Green : DependencyProperty.UnsetValue;

    public object ConvertBack(object value, Type targetType, object parameter, string language)
        => throw new NotSupportedException();
}

public sealed class ActiveToForegroundConverter : IValueConverter
{
    private static readonly SolidColorBrush White =
        new(Microsoft.UI.Colors.White);

    public object Convert(object value, Type targetType, object parameter, string language)
        => value is true ? White : DependencyProperty.UnsetValue;

    public object ConvertBack(object value, Type targetType, object parameter, string language)
        => throw new NotSupportedException();
}
