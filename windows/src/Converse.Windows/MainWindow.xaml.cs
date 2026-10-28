using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Converse.App;

// Milestone-2 shell: dense sidebar + up to three panes, mirroring the Mac
// Workspace model (P parks, 1/2/3 place, one display per session).
// Session engine and device sync bind in via Converse.Core view models.
public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        Title = "Converse";
    }

    private void OnNewSessionClick(object sender, RoutedEventArgs e)
    {
        // TODO (milestone 2): provider/account picker, then assign first free pane.
    }

    private void OnConnectClick(object sender, RoutedEventArgs e)
    {
        // TODO (milestone 2): pairing sheet (nearby + manual address, compare ALL 8 groups).
    }

    private void OnParkClick(object sender, RoutedEventArgs e)
    {
        // TODO (milestone 2): release remote lease if held, then park placement.
    }

    private void OnPaneClick(object sender, RoutedEventArgs e)
    {
        // TODO (milestone 2): acquire lease for remote rows, assign placement.
    }
}
