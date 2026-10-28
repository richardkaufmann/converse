using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;

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
