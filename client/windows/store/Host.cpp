#include <windows.h>
#include <appmodel.h>
#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Networking.h>
#include <winrt/Windows.Networking.Vpn.h>
#include <chrono>
#include <iostream>
#include <string>
#include <vector>

using namespace winrt;
using namespace Windows::Foundation;
using namespace Windows::Networking;
using namespace Windows::Networking::Vpn;
namespace {
template<typename T> auto bounded(T const& operation) {
    if (operation.wait_for(std::chrono::seconds(30)) == AsyncStatus::Started) {
        operation.Cancel(); throw hresult_error(HRESULT_FROM_WIN32(ERROR_TIMEOUT), L"Windows VPN 操作超时");
    }
    return operation.GetResults();
}
void requireOK(VpnManagementErrorStatus status, wchar_t const* operation) {
    if (status != VpnManagementErrorStatus::Ok)
        throw hresult_error(E_FAIL, std::wstring(operation) + L"失败，Windows VPN 状态码 " + std::wstring(to_hstring(uint32_t(status))));
}
}
int wmain(int argc, wchar_t** argv) {
    SetConsoleOutputCP(CP_UTF8);
    try {
        init_apartment(apartment_type::multi_threaded);
        if (argc != 2) throw hresult_invalid_argument(L"需要 connect、disconnect 或 status");
        std::wstring action(argv[1]);
        if (action != L"connect" && action != L"disconnect" && action != L"status") throw hresult_invalid_argument();
        uint32_t size = 0;
        if (GetCurrentPackageFamilyName(&size, nullptr) != ERROR_INSUFFICIENT_BUFFER) throw hresult_error(E_ACCESSDENIED, L"请通过 Celium 商店应用启动");
        std::vector<wchar_t> name(size);
        check_hresult(HRESULT_FROM_WIN32(GetCurrentPackageFamilyName(&size, name.data())));
        hstring family(name.data());
        VpnManagementAgent agent;
        VpnPlugInProfile profile{nullptr};
        for (auto const& p : bounded(agent.GetProfilesAsync())) {
            if (p.ProfileName() != L"Celium Store") continue;
            auto candidate = p.try_as<VpnPlugInProfile>();
            if (!candidate || candidate.VpnPluginPackageFamilyName() != family)
                throw hresult_error(E_ACCESSDENIED, L"同名 VPN 配置属于其他应用，未修改该配置");
            profile = candidate;
        }
        if (!profile && action == L"connect") {
            profile = VpnPlugInProfile();
            profile.ProfileName(L"Celium Store");
            profile.VpnPluginPackageFamilyName(family);
            profile.ServerUris().Append(Uri(L"https://login.celium.cn"));
            profile.RememberCredentials(false);
            profile.AlwaysOn(false);
            profile.RequireVpnClientAppUI(false);
            // An explicit private route keeps this a split tunnel profile.
            // A selected exit adds two /1 routes in the plug-in at Connect.
            profile.Routes().Append(VpnRoute(HostName(L"10.239.0.0"), 16));
            requireOK(bounded(agent.AddProfileFromObjectAsync(profile)), L"创建 VPN 配置");
        }
        if (!profile) { std::cout << "Stopped\n"; return 0; }
        if (action == L"connect" && profile.ConnectionStatus() != VpnManagementConnectionStatus::Connected)
            requireOK(bounded(agent.ConnectProfileAsync(profile)), L"连接 VPN");
        else if (action == L"disconnect" && profile.ConnectionStatus() != VpnManagementConnectionStatus::Disconnected)
            requireOK(bounded(agent.DisconnectProfileAsync(profile)), L"断开 VPN");
        std::cout << "OK\n";
        return 0;
    } catch (hresult_error const& e) {
        std::cerr << to_string(e.message()) << " (0x" << std::hex << uint32_t(e.code()) << ")\n";
    } catch (...) { std::cerr << "Windows VPN operation failed\n"; }
    return 1;
}
