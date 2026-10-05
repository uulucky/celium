// A single visible UWP identity owns the VPN task and starts the desktop UI.
// Consolidate only this launcher view, never exit the VPN host process.
#include <windows.h>
#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.ApplicationModel.Activation.h>
#include <winrt/Windows.ApplicationModel.Core.h>
#include <winrt/Windows.ApplicationModel.h>
#include <winrt/Windows.UI.Core.h>
#include <winrt/Windows.UI.ViewManagement.h>
#include <winrt/Windows.UI.Popups.h>

using namespace winrt;
using namespace Windows::ApplicationModel::Core;
using namespace Windows::UI::Core;
struct View : implements<View, IFrameworkView> {
    CoreWindow window{nullptr};
    bool launching = false;
    fire_and_forget OpenDesktop() {
        auto lifetime = get_strong();
        if (launching) co_return;
        launching = true;
        hstring error;
        try {
            window.Activate();
            co_await Windows::ApplicationModel::FullTrustProcessLauncher::LaunchFullTrustProcessForCurrentAppAsync(L"Desktop");
            // Closing the launcher view leaves background VPN tasks alive.
            co_await Windows::UI::ViewManagement::ApplicationView::GetForCurrentView().TryConsolidateAsync();
        } catch (hresult_error const& e) { error = e.message(); }
        launching = false;
        if (!error.empty()) {
            try { co_await Windows::UI::Popups::MessageDialog(error, L"Celium 无法打开").ShowAsync(); }
            catch (...) {}
        }
    }
    void Initialize(CoreApplicationView const& view) {
        view.Activated([weak = get_weak()](auto const&, auto const&) {
            if (auto self = weak.get()) self->OpenDesktop();
        });
    }
    void SetWindow(CoreWindow const& value) { window = value; }
    void Load(hstring const&) {}
    void Run() { window.Dispatcher().ProcessEvents(CoreProcessEventsOption::ProcessUntilQuit); }
    void Uninitialize() { window = nullptr; }
};
struct ViewSource : implements<ViewSource, IFrameworkViewSource> {
    IFrameworkView CreateView() { return make<View>(); }
};
int __stdcall wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
    init_apartment(apartment_type::multi_threaded);
    CoreApplication::Run(make<ViewSource>());
    return 0;
}
