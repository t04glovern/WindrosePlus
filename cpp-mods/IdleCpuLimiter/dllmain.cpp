#define NOMINMAX

#include <Mod/CppUserModBase.hpp>
#include <DynamicOutput/DynamicOutput.hpp>
#include <windows.h>

#include <algorithm>
#include <chrono>
#include <cctype>
#include <filesystem>
#include <fstream>
#include <optional>
#include <string>

using namespace RC;

class IdleCpuLimiter : public CppUserModBase {
public:
    IdleCpuLimiter() : CppUserModBase() {
        ModName = STR("IdleCpuLimiter");
        ModVersion = STR("1.0.0");
    }

    ~IdleCpuLimiter() override {}

    auto on_unreal_init() -> void override {
        m_startedAt = std::chrono::steady_clock::now();
        initializeJob();
        Output::send<LogLevel::Verbose>(STR("[IdleCpuLimiter] ready\n"));
    }

    auto on_update() -> void override {
        try {
            refreshState();
        } catch (...) {
            m_isIdle = false;
            applyCpuRate(false);
        }
    }

private:
    int m_idleCpuRate = 200;
    int m_appliedCpuRate = 0;
    bool m_isIdle = false;
    bool m_limitApplied = false;
    HANDLE m_job = nullptr;
    std::chrono::steady_clock::time_point m_startedAt = std::chrono::steady_clock::now();
    std::chrono::steady_clock::time_point m_lastStatusRead = std::chrono::steady_clock::time_point::min();

    void initializeJob() {
        wchar_t name[128]{};
        swprintf_s(name, L"WindrosePlusIdleCpuLimiter_%lu", GetCurrentProcessId());

        m_job = CreateJobObjectW(nullptr, name);
        if (!m_job) {
            Output::send<LogLevel::Verbose>(STR("[IdleCpuLimiter] CreateJobObject failed: {}\n"), GetLastError());
            return;
        }

        if (!AssignProcessToJobObject(m_job, GetCurrentProcess())) {
            const auto err = GetLastError();
            Output::send<LogLevel::Verbose>(STR("[IdleCpuLimiter] AssignProcessToJobObject failed: {}\n"), err);
            CloseHandle(m_job);
            m_job = nullptr;
        }
    }

    void refreshState() {
        const auto now = std::chrono::steady_clock::now();
        if (m_lastStatusRead != std::chrono::steady_clock::time_point::min() &&
            now - m_lastStatusRead < std::chrono::seconds(1)) {
            return;
        }
        m_lastStatusRead = now;

        const auto dataDir = findDataDir();
        if (!dataDir) {
            m_isIdle = false;
            return;
        }

        if (std::filesystem::exists(*dataDir / "idle_cpu_limiter_disabled")) {
            m_isIdle = false;
            applyCpuRate(false);
            return;
        }

        refreshCpuRate(*dataDir);
        refreshPlayerState(*dataDir);
        applyCpuRate(shouldLimitIdleCpu());
    }

    std::optional<std::filesystem::path> findDataDir() const {
        const std::filesystem::path candidates[] = {
            "../../../windrose_plus_data",
            "windrose_plus_data"
        };

        for (const auto& candidate : candidates) {
            std::error_code ec;
            if (std::filesystem::is_directory(candidate, ec)) {
                return candidate;
            }
        }
        return std::nullopt;
    }

    bool shouldLimitIdleCpu() const {
        const auto uptime = std::chrono::steady_clock::now() - m_startedAt;
        return m_isIdle && uptime >= std::chrono::seconds(45);
    }

    void refreshCpuRate(const std::filesystem::path& dataDir) {
        std::ifstream file(dataDir / "idle_cpu_limiter_cpu_rate.txt");
        if (!file) {
            m_idleCpuRate = 200;
            return;
        }

        int value = 200;
        file >> value;
        m_idleCpuRate = std::clamp(value, 100, 10000);
    }

    void refreshPlayerState(const std::filesystem::path& dataDir) {
        const auto statusPath = dataDir / "server_status.json";
        std::error_code ec;
        const auto lastWrite = std::filesystem::last_write_time(statusPath, ec);
        if (ec) {
            m_isIdle = false;
            return;
        }

        const auto age = std::filesystem::file_time_type::clock::now() - lastWrite;
        if (age > std::chrono::seconds(120)) {
            m_isIdle = false;
            return;
        }

        std::ifstream file(statusPath);
        if (!file) {
            m_isIdle = false;
            return;
        }

        const std::string json((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
        const auto playerCount = parsePlayerCount(json);
        m_isIdle = playerCount.has_value() && *playerCount == 0;
    }

    void applyCpuRate(bool shouldLimit) {
        if (!m_job || (shouldLimit == m_limitApplied && (!shouldLimit || m_idleCpuRate == m_appliedCpuRate))) {
            return;
        }

        JOBOBJECT_CPU_RATE_CONTROL_INFORMATION info{};
        info.ControlFlags = JOB_OBJECT_CPU_RATE_CONTROL_ENABLE | JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP;
        info.CpuRate = shouldLimit ? static_cast<DWORD>(m_idleCpuRate) : 10000;

        if (SetInformationJobObject(m_job, JobObjectCpuRateControlInformation, &info, sizeof(info))) {
            m_limitApplied = shouldLimit;
            m_appliedCpuRate = shouldLimit ? m_idleCpuRate : 10000;
            Output::send<LogLevel::Verbose>(
                STR("[IdleCpuLimiter] {} CPU rate {}\n"),
                shouldLimit ? STR("applied idle") : STR("lifted idle"),
                info.CpuRate);
        } else {
            Output::send<LogLevel::Verbose>(STR("[IdleCpuLimiter] SetInformationJobObject failed: {}\n"), GetLastError());
        }
    }

    std::optional<int> parsePlayerCount(const std::string& json) const {
        const std::string key = "\"player_count\"";
        const auto keyPos = json.find(key);
        if (keyPos == std::string::npos) {
            return std::nullopt;
        }

        const auto colonPos = json.find(':', keyPos + key.size());
        if (colonPos == std::string::npos) {
            return std::nullopt;
        }

        auto pos = colonPos + 1;
        while (pos < json.size() && std::isspace(static_cast<unsigned char>(json[pos]))) {
            ++pos;
        }

        int count = 0;
        bool foundDigit = false;
        while (pos < json.size() && std::isdigit(static_cast<unsigned char>(json[pos]))) {
            foundDigit = true;
            count = (count * 10) + (json[pos] - '0');
            ++pos;
        }

        if (!foundDigit) {
            return std::nullopt;
        }
        return count;
    }
};

extern "C" __declspec(dllexport) RC::CppUserModBase* start_mod() { return new IdleCpuLimiter(); }
extern "C" __declspec(dllexport) void uninstall_mod(RC::CppUserModBase* mod) { delete mod; }
