<?php
$pluginName = 'power.optimizer';
$configDir = "/boot/config/plugins/{$pluginName}";
$configFile = "{$configDir}/settings.cfg";
$stateDir = "{$configDir}/state";
$pcieScriptFile = "/usr/local/emhttp/plugins/{$pluginName}/scripts/pcie_power.sh";
$cpuScriptFile = "/usr/local/emhttp/plugins/{$pluginName}/scripts/cpu_power.sh";
$ethernetScriptFile = "/usr/local/emhttp/plugins/{$pluginName}/scripts/ethernet_power.sh";
$disksScriptFile = "/usr/local/emhttp/plugins/{$pluginName}/scripts/disks_power.sh";
$disksSpinDownScriptFile = "/usr/local/emhttp/plugins/{$pluginName}/scripts/disks_spin_down_all.sh";
$usbScriptFile = "/usr/local/emhttp/plugins/{$pluginName}/scripts/usb_power.sh";
$i2cScriptFile = "/usr/local/emhttp/plugins/{$pluginName}/scripts/i2c_power.sh";
$systemTunablesScriptFile = "/usr/local/emhttp/plugins/{$pluginName}/scripts/system_tunables_power.sh";
$logBaseDir = '/boot/logs';
$syslinuxFile = '/boot/syslinux/syslinux.cfg';
$notifyScript = '/usr/local/emhttp/webGui/scripts/notify';

function send_json(int $status, array $payload): void
{
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($payload);
    exit;
}

function default_settings(): array
{
    return [
        'BLACK_LIST' => 'Example1,Example2',
        'AUTO_EXECUTE_ON_STARTUP' => '0',
        'OPERATION_MODE' => 'automatic',
        'MAX_ASPM_LEVEL' => '3',
        'ENABLE_ASPM_OPTIMIZATION' => '1',
        'ENABLE_CLKPM_OPTIMIZATION' => '1',
        'ENABLE_LTR_OPTIMIZATION' => '1',
        'ENABLE_L1SS_OPTIMIZATION' => '0',
        'ENABLE_PCI_RUNTIME_PM_OPTIMIZATION' => '1',
        'FORCE_ASPM_ENDPOINT_MODE' => '0',
        'FORCE_ASPM_BRIDGE_MODE' => '0',
        'MANUAL_FORCE_INCOMPATIBLE' => '0',
        'MANUAL_SELECTED_DEVICES' => '',
        'MANUAL_DEVICE_OPTIONS' => '',

        'CPU_MODE' => 'automatic',
        'CPU_AUTO_EXECUTE_ON_STARTUP' => '0',
        'CPU_GOVERNOR_MODE' => 'powersave',
        'CPU_TURBO_MODE' => 'disabled',

        'ETHERNET_MODE' => 'automatic',
        'ETHERNET_AUTO_EXECUTE_ON_STARTUP' => '0',
        'ENABLE_ETHERNET_EEE_OPTIMIZATION' => '1',
        'ETHERNET_EEE_TARGET' => 'on',
        'ENABLE_ETHERNET_WOL_OPTIMIZATION' => '1',
        'ETHERNET_WOL_TARGET' => 'd',
        'ETHERNET_MANUAL_INTERFACES' => '',

        'DISKS_MODE' => 'automatic',
        'DISKS_AUTO_EXECUTE_ON_STARTUP' => '0',
        'SATA_LPM_MODE' => 'min_power',
        'DISK_RUNTIME_PM_MODE' => 'auto',
        'ATA_RUNTIME_PM_MODE' => 'auto',
        'NVME_APST_MODE' => 'enabled',
        'NVME_RUNTIME_PM_MODE' => 'auto',

        'USB_MODE' => 'automatic',
        'USB_AUTO_EXECUTE_ON_STARTUP' => '0',
        'ENABLE_USB_AUTOSUSPEND_OPTIMIZATION' => '1',
        'USB_RUNTIME_PM_TARGET' => 'auto',
        'ENABLE_USB_WAKEUP_OPTIMIZATION' => '1',
        'USB_WAKEUP_TARGET' => 'disabled',
        'USB_DEVICE_GLOB' => '*',

        'I2C_MODE' => 'automatic',
        'I2C_AUTO_EXECUTE_ON_STARTUP' => '0',
        'I2C_RUNTIME_PM_MODE' => 'on',
        'I2C_DEVICE_GLOB' => 'i2c-*',

        'SYSTEM_AUTO_EXECUTE_ON_STARTUP' => '0',

        'ENABLE_AUDIO_CODEC_PM_OPTIMIZATION' => '1',
        'AUDIO_CODEC_POWER_SAVE_SECONDS' => '1',
        'ENABLE_NMI_WATCHDOG_OPTIMIZATION' => '1',
        'NMI_WATCHDOG_TARGET' => '0',
        'ENABLE_VM_WRITEBACK_TIMEOUT_OPTIMIZATION' => '1',
        'VM_DIRTY_WRITEBACK_CENTISECS' => '1500',
        'VM_LAPTOP_MODE' => '5',
        'VM_DIRTY_EXPIRE_CENTISECS' => '6000',
        'VFS_CACHE_PRESSURE' => '1',
        'VFS_CACHE_MAX_AGE' => '60000',
        'ENABLE_DISK_METADATA_CACHE_WARMUP' => '1',
        'ENABLE_USER_SHARE_METADATA_CACHE_WARMUP' => '0',
        'ZFS_ARC_MIN_PERCENT' => '10',
        'ZFS_ARC_MAX_PERCENT' => '40',
        'POWER_AWARE_CPU_SCHEDULER_MODE' => '2',
        'NUMA_BALANCING_TARGET' => '0',
    ];
}

function parse_key_value_file(string $path): array
{
    if (!is_file($path)) {
        return [];
    }

    $contents = file($path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    if ($contents === false) {
        return [];
    }

    $result = [];
    foreach ($contents as $line) {
        $parts = explode('=', $line, 2);
        if (count($parts) !== 2) {
            continue;
        }

        $key = trim($parts[0]);
        $value = trim($parts[1]);
        $value = trim($value, "\"'");
        $result[$key] = $value;
    }

    return $result;
}

function read_raw_settings(string $configFile, array $defaults): array
{
    $raw = $defaults;
    $pairs = parse_key_value_file($configFile);

    foreach ($defaults as $key => $defaultValue) {
        if (array_key_exists($key, $pairs)) {
            $raw[$key] = $pairs[$key];
        }
    }

    return $raw;
}

function write_raw_settings(string $configDir, string $configFile, array $defaults, array $updatedRaw): bool
{
    if (!is_dir($configDir) && !mkdir($configDir, 0775, true) && !is_dir($configDir)) {
        return false;
    }

    $merged = $defaults;
    foreach ($defaults as $key => $defaultValue) {
        if (array_key_exists($key, $updatedRaw)) {
            $merged[$key] = (string)$updatedRaw[$key];
        }
    }

    $payload = '';
    foreach ($defaults as $key => $_) {
        $payload .= $key . '="' . $merged[$key] . '"' . PHP_EOL;
    }

    return file_put_contents($configFile, $payload, LOCK_EX) !== false;
}

function normalize_csv_items(string $raw): array
{
    $normalized = str_replace(["\r\n", "\r"], "\n", $raw);
    $normalized = str_replace(';', ',', $normalized);
    $normalized = str_replace("\n", ',', $normalized);

    $items = array_filter(array_map(static function ($entry) {
        $entry = trim($entry);
        $entry = str_replace(['"', "'"], '', $entry);
        return $entry;
    }, explode(',', $normalized)), static function ($entry) {
        return $entry !== '';
    });

    return array_values(array_unique($items));
}

function normalize_pci_device_identifier(string $value): string
{
    $normalized = normalize_pci_device_id($value);
    return preg_match('/^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$/', $normalized) === 1
        ? $normalized
        : '';
}

function default_manual_device_profile(): array
{
    return [
        'enabled' => 0,
        'enable_aspm' => 1,
        'aspm_mode' => 3,
        'enable_clkpm' => 1,
        'enable_ltr' => 1,
        'enable_l1ss' => 0,
        'enable_runtime_pm' => 0,
    ];
}

function normalize_manual_device_profile(array $profile): array
{
    $defaults = default_manual_device_profile();
    $enableAspm = normalize_boolean($profile['enable_aspm'] ?? null, $defaults['enable_aspm']);

    $aspmModeRaw = strtolower(trim((string)($profile['aspm_mode'] ?? $defaults['aspm_mode'])));
    if (in_array($aspmModeRaw, ['0', 'disabled', 'off', 'none', 'no-change', 'no_change', 'nochange'], true)) {
        $aspmMode = 0;
    } else {
        $aspmMode = normalize_aspm_level($aspmModeRaw, $defaults['aspm_mode']);
    }

    if (!in_array($aspmMode, [0, 1, 2, 3], true)) {
        $aspmMode = $defaults['aspm_mode'];
    }

    if ($enableAspm === 0 || $aspmMode === 0) {
        $enableAspm = 0;
        $aspmMode = 0;
    } else {
        $enableAspm = 1;
    }

    return [
        'enabled' => normalize_boolean($profile['enabled'] ?? null, $defaults['enabled']),
        'enable_aspm' => $enableAspm,
        'aspm_mode' => $aspmMode,
        'enable_clkpm' => normalize_boolean($profile['enable_clkpm'] ?? null, $defaults['enable_clkpm']),
        'enable_ltr' => normalize_boolean($profile['enable_ltr'] ?? null, $defaults['enable_ltr']),
        'enable_l1ss' => normalize_boolean($profile['enable_l1ss'] ?? null, $defaults['enable_l1ss']),
        'enable_runtime_pm' => normalize_boolean($profile['enable_runtime_pm'] ?? null, $defaults['enable_runtime_pm']),
    ];
}

function decode_manual_device_options(string $raw): array
{
    $result = [];
    $entries = array_filter(array_map('trim', explode(';', $raw)), static function ($entry): bool {
        return $entry !== '';
    });

    foreach ($entries as $entry) {
        $parts = array_map('trim', explode(',', $entry));
        if (count($parts) !== 8) {
            continue;
        }

        $deviceId = normalize_pci_device_identifier((string)$parts[0]);
        if ($deviceId === '') {
            continue;
        }

        $result[$deviceId] = normalize_manual_device_profile([
            'enabled' => $parts[1],
            'enable_aspm' => $parts[2],
            'aspm_mode' => $parts[3],
            'enable_clkpm' => $parts[4],
            'enable_ltr' => $parts[5],
            'enable_l1ss' => $parts[6],
            'enable_runtime_pm' => $parts[7],
        ]);
    }

    ksort($result, SORT_STRING);
    return $result;
}

function encode_manual_device_options(array $options): string
{
    if (count($options) === 0) {
        return '';
    }

    $encodedEntries = [];
    ksort($options, SORT_STRING);
    foreach ($options as $deviceId => $profile) {
        $normalizedId = normalize_pci_device_identifier((string)$deviceId);
        if ($normalizedId === '') {
            continue;
        }

        $normalizedProfile = normalize_manual_device_profile((array)$profile);
        $encodedEntries[] = implode(',', [
            $normalizedId,
            (string)$normalizedProfile['enabled'],
            (string)$normalizedProfile['enable_aspm'],
            (string)$normalizedProfile['aspm_mode'],
            (string)$normalizedProfile['enable_clkpm'],
            (string)$normalizedProfile['enable_ltr'],
            (string)$normalizedProfile['enable_l1ss'],
            (string)$normalizedProfile['enable_runtime_pm'],
        ]);
    }

    return implode(';', $encodedEntries);
}

function normalize_manual_device_options_from_post($raw): array
{
    if (!is_string($raw) || trim($raw) === '') {
        return [];
    }

    $decoded = json_decode($raw, true);
    if (!is_array($decoded)) {
        return [];
    }

    $result = [];
    foreach ($decoded as $deviceId => $profile) {
        if (!is_array($profile)) {
            continue;
        }

        $normalizedId = normalize_pci_device_identifier((string)$deviceId);
        if ($normalizedId === '') {
            continue;
        }

        $result[$normalizedId] = normalize_manual_device_profile($profile);
    }

    ksort($result, SORT_STRING);
    return $result;
}

function normalize_boolean($value, int $default = 1): int
{
    if ($value === null) {
        return $default;
    }

    $normalized = strtolower(trim((string)$value));
    return in_array($normalized, ['1', 'true', 'yes', 'on', 'enabled'], true) ? 1 : 0;
}

function normalize_mode($value, string $default = 'automatic'): string
{
    $normalized = strtolower(trim((string)$value));
    return in_array($normalized, ['automatic', 'manual'], true) ? $normalized : $default;
}

function normalize_aspm_level($value, int $default = 3): int
{
    $normalized = strtolower(trim((string)$value));
    if ($normalized === '1') {
        return 1;
    }
    if ($normalized === '2') {
        return 2;
    }
    if ($normalized === '3') {
        return 3;
    }
    return $default;
}

function normalize_force_aspm_mode($value, int $default = 0): int
{
    $normalized = strtolower(trim((string)$value));
    if ($normalized === '0') {
        return 0;
    }
    if ($normalized === '1') {
        return 1;
    }
    if ($normalized === '2') {
        return 2;
    }
    if ($normalized === '3') {
        return 3;
    }
    if ($normalized === '4') {
        return 4;
    }
    return $default;
}

function normalize_governor($value, string $default = 'powersave'): string
{
    $allowed = ['powersave', 'ondemand', 'performance', 'conservative', 'schedutil'];
    $normalized = strtolower(trim((string)$value));
    return in_array($normalized, $allowed, true) ? $normalized : $default;
}

function normalize_cpu_governor_mode($value, string $default = 'disabled'): string
{
    $normalized = strtolower(trim((string)$value));
    if ($normalized === 'disabled' || $normalized === 'off') {
        return 'disabled';
    }

    return normalize_governor($normalized, $default);
}

function normalize_cpu_turbo_mode($value, string $default = 'disabled'): string
{
    $normalized = strtolower(trim((string)$value));

    if (in_array($normalized, ['force_enabled', 'enabled', 'enable', 'on', '1', 'true'], true)) {
        return 'force_enabled';
    }

    if (in_array($normalized, ['force_disabled', 'disable', 'target_disabled', '0', 'false'], true)) {
        return 'force_disabled';
    }

    if (in_array($normalized, ['disabled', 'off', 'none'], true)) {
        return 'disabled';
    }

    return $default;
}

function normalize_on_off($value, string $default = 'on'): string
{
    $normalized = strtolower(trim((string)$value));
    return in_array($normalized, ['on', 'off'], true) ? $normalized : $default;
}

function normalize_wol_target($value, string $default = 'd'): string
{
    $normalized = strtolower(trim((string)$value));
    return in_array($normalized, ['d', 'g'], true) ? $normalized : $default;
}

function normalize_runtime_target($value, string $default = 'auto'): string
{
    $normalized = strtolower(trim((string)$value));
    return in_array($normalized, ['auto', 'on'], true) ? $normalized : $default;
}

function normalize_usb_runtime_pm_target($value, string $default = 'auto'): string
{
    $normalized = strtolower(trim((string)$value));
    if ($normalized === 'auto') {
        return 'auto';
    }

    if (in_array($normalized, ['disabled', 'off'], true)) {
        return 'disabled';
    }

    return $default;
}

function normalize_runtime_pm_mode($value, string $default = 'auto'): string
{
    $normalized = strtolower(trim((string)$value));
    if ($normalized === 'disabled' || $normalized === 'off') {
        return 'disabled';
    }

    return normalize_runtime_target($normalized, $default);
}

function normalize_disks_runtime_pm_mode($value, string $default = 'auto'): string
{
    $normalized = strtolower(trim((string)$value));
    if ($normalized === 'disabled' || $normalized === 'off') {
        return 'disabled';
    }

    return $normalized === 'auto' ? 'auto' : $default;
}

function normalize_sata_policy($value, string $default = 'med_power_with_dipm'): string
{
    $normalized = strtolower(trim((string)$value));
    $allowed = ['max_performance', 'med_power_with_dipm', 'min_power'];
    return in_array($normalized, $allowed, true) ? $normalized : $default;
}

function normalize_sata_lpm_mode($value, string $default = 'min_power'): string
{
    $normalized = strtolower(trim((string)$value));
    if ($normalized === 'disabled' || $normalized === 'off') {
        return 'disabled';
    }

    return normalize_sata_policy($normalized, $default);
}

function sata_lpm_mode_from_raw(array $raw): string
{
    return normalize_sata_lpm_mode($raw['SATA_LPM_MODE'] ?? 'min_power', 'min_power');
}

function normalize_nvme_apst_mode($value, string $default = 'enabled'): string
{
    $normalized = strtolower(trim((string)$value));
    if ($normalized === 'disabled' || $normalized === 'off') {
        return 'disabled';
    }

    if ($normalized === 'enabled' || $normalized === 'on') {
        return 'enabled';
    }

    return $default;
}

function normalize_int_range($value, int $default, int $min, int $max): int
{
    $normalized = trim((string)$value);
    if ($normalized === '' || preg_match('/^-?\d+$/', $normalized) !== 1) {
        return $default;
    }

    $number = (int)$normalized;
    if ($number < $min) {
        return $min;
    }
    if ($number > $max) {
        return $max;
    }

    return $number;
}

function normalize_power_aware_scheduler_mode($value, int $default = 2): int
{
    return normalize_int_range($value, $default, 0, 2);
}

function power_aware_scheduler_mode_from_raw(array $raw): int
{
    return normalize_power_aware_scheduler_mode($raw['POWER_AWARE_CPU_SCHEDULER_MODE'] ?? 2, 2);
}

function normalize_runtime_target_list(array $targets): array
{
    $allowed = ['auto', 'on'];
    $seen = [];
    $result = [];

    foreach ($targets as $target) {
        $normalized = strtolower(trim((string)$target));
        if (!in_array($normalized, $allowed, true) || isset($seen[$normalized])) {
            continue;
        }

        $seen[$normalized] = true;
        $result[] = $normalized;
    }

    if (count($result) === 0) {
        return ['auto', 'on'];
    }

    return $result;
}

function discover_runtime_pm_targets(array $globPatterns): array
{
    $targets = [];

    foreach ($globPatterns as $pattern) {
        $matches = glob($pattern);
        if ($matches === false) {
            continue;
        }

        foreach ($matches as $path) {
            if (!is_readable($path)) {
                continue;
            }

            $raw = @file_get_contents($path);
            if ($raw === false) {
                continue;
            }

            if (preg_match_all('/\[?([a-z0-9_]+)\]?/i', (string)$raw, $valueMatches) !== 1) {
                continue;
            }

            foreach ($valueMatches[1] as $token) {
                $normalized = strtolower(trim((string)$token));
                if (in_array($normalized, ['auto', 'on'], true)) {
                    $targets[] = $normalized;
                }
            }
        }
    }

    return normalize_runtime_target_list($targets);
}

function cpu_capabilities(): array
{
    $allowed = ['powersave', 'ondemand', 'conservative', 'schedutil', 'performance'];
    $preferredOrder = ['powersave', 'ondemand', 'conservative', 'schedutil', 'performance'];
    $seen = [];

    $availableGovernorFiles = glob('/sys/devices/system/cpu/cpufreq/policy*/scaling_available_governors');
    if ($availableGovernorFiles !== false) {
        foreach ($availableGovernorFiles as $path) {
            if (!is_readable($path)) {
                continue;
            }

            $raw = @file_get_contents($path);
            if ($raw === false) {
                continue;
            }

            foreach (preg_split('/\s+/', strtolower(trim((string)$raw))) as $token) {
                if (in_array($token, $allowed, true)) {
                    $seen[$token] = true;
                }
            }
        }
    }

    if (count($seen) === 0) {
        $activeGovernorFiles = glob('/sys/devices/system/cpu/cpufreq/policy*/scaling_governor');
        if ($activeGovernorFiles !== false) {
            foreach ($activeGovernorFiles as $path) {
                if (!is_readable($path)) {
                    continue;
                }

                $raw = @file_get_contents($path);
                if ($raw === false) {
                    continue;
                }

                $token = strtolower(trim((string)$raw));
                if (in_array($token, $allowed, true)) {
                    $seen[$token] = true;
                }
            }
        }
    }

    $availableGovernors = [];
    foreach ($preferredOrder as $governor) {
        if (isset($seen[$governor])) {
            $availableGovernors[] = $governor;
        }
    }

    $supportsCpuTurbo = is_file('/sys/devices/system/cpu/cpufreq/boost')
        || is_file('/sys/devices/system/cpu/intel_pstate/no_turbo');

    return [
        'available_governors' => $availableGovernors,
        'supports_cpu_turbo' => $supportsCpuTurbo,
    ];
}

function read_trimmed_file_value(string $path): ?string
{
    if (!is_readable($path)) {
        return null;
    }

    $raw = @file_get_contents($path);
    if ($raw === false) {
        return null;
    }

    return trim(str_replace(["\r", "\n"], ' ', (string)$raw));
}

function current_cpu_governor_label(): string
{
    $governorFiles = glob('/sys/devices/system/cpu/cpufreq/policy*/scaling_governor');
    if ($governorFiles === false || count($governorFiles) === 0) {
        $governorFiles = ['/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor'];
    }

    $seen = [];
    foreach ($governorFiles as $path) {
        $value = read_trimmed_file_value($path);
        if ($value === null || $value === '') {
            continue;
        }

        $seen[strtolower($value)] = true;
    }

    if (count($seen) === 0) {
        return 'unknown';
    }

    $governors = array_keys($seen);
    sort($governors, SORT_STRING);

    if (count($governors) === 1) {
        return $governors[0];
    }

    return 'mixed (' . implode(', ', $governors) . ')';
}

function cpu_frequency_ghz_samples(): array
{
    $samples = [];

    $freqFiles = glob('/sys/devices/system/cpu/cpufreq/policy*/scaling_cur_freq');
    if ($freqFiles !== false) {
        foreach ($freqFiles as $path) {
            $value = read_trimmed_file_value($path);
            if ($value === null || preg_match('/^\d+$/', $value) !== 1) {
                continue;
            }

            $khz = (int)$value;
            if ($khz > 0) {
                $samples[] = $khz / 1000000.0;
            }
        }
    }

    if (count($samples) === 0 && is_readable('/proc/cpuinfo')) {
        $cpuInfo = @file_get_contents('/proc/cpuinfo');
        if ($cpuInfo !== false && preg_match_all('/^cpu MHz\s*:\s*([0-9]+(?:\.[0-9]+)?)/mi', (string)$cpuInfo, $matches) >= 1) {
            foreach ($matches[1] as $mhzValue) {
                $mhz = (float)$mhzValue;
                if ($mhz > 0) {
                    $samples[] = $mhz / 1000.0;
                }
            }
        }
    }

    return $samples;
}

function cpu_frequency_ghz_stats(): array
{
    $samples = cpu_frequency_ghz_samples();
    if (count($samples) === 0) {
        return [
            'average' => null,
            'min' => null,
            'max' => null,
        ];
    }

    return [
        'average' => array_sum($samples) / count($samples),
        'min' => min($samples),
        'max' => max($samples),
    ];
}

function cpu_c_state_time_totals_us(): array
{
    $totals = [];
    $timeFiles = glob('/sys/devices/system/cpu/cpu*/cpuidle/state*/time');
    if ($timeFiles === false) {
        return $totals;
    }

    foreach ($timeFiles as $timePath) {
        $timeValue = read_trimmed_file_value($timePath);
        if ($timeValue === null || preg_match('/^\d+$/', $timeValue) !== 1) {
            continue;
        }

        $namePath = dirname($timePath) . '/name';
        $stateName = read_trimmed_file_value($namePath) ?? basename(dirname($timePath));
        $stateName = strtoupper(preg_replace('/\s+/', '', $stateName));
        if ($stateName === '') {
            continue;
        }

        if (!isset($totals[$stateName])) {
            $totals[$stateName] = 0;
        }

        $totals[$stateName] += (int)$timeValue;
    }

    ksort($totals, SORT_STRING);
    return $totals;
}

function cpu_c_state_time_totals_us_by_package(): array
{
    $byPackage = [];
    $timeFiles = glob('/sys/devices/system/cpu/cpu*/cpuidle/state*/time');
    if ($timeFiles === false) {
        return $byPackage;
    }

    foreach ($timeFiles as $timePath) {
        if (preg_match('#/cpu([0-9]+)/cpuidle/state[^/]+/time$#', $timePath, $matches) !== 1) {
            continue;
        }

        $cpuIndex = (int)$matches[1];
        $packagePath = '/sys/devices/system/cpu/cpu' . $cpuIndex . '/topology/physical_package_id';
        $packageValue = read_trimmed_file_value($packagePath);
        $packageId = preg_match('/^-?\d+$/', (string)$packageValue) === 1
            ? (int)$packageValue
            : $cpuIndex;

        $timeValue = read_trimmed_file_value($timePath);
        if ($timeValue === null || preg_match('/^\d+$/', $timeValue) !== 1) {
            continue;
        }

        $namePath = dirname($timePath) . '/name';
        $stateName = read_trimmed_file_value($namePath) ?? basename(dirname($timePath));
        $stateName = strtoupper(preg_replace('/\s+/', '', $stateName));
        if ($stateName === '') {
            continue;
        }

        $packageKey = (string)$packageId;
        if (!isset($byPackage[$packageKey])) {
            $byPackage[$packageKey] = [];
        }
        if (!isset($byPackage[$packageKey][$stateName])) {
            $byPackage[$packageKey][$stateName] = 0;
        }

        $byPackage[$packageKey][$stateName] += (int)$timeValue;
    }

    foreach ($byPackage as &$totals) {
        ksort($totals, SORT_STRING);
    }
    unset($totals);

    ksort($byPackage, SORT_NATURAL);
    return $byPackage;
}

function cpu_live_statistics(): array
{
    $frequencyStats = cpu_frequency_ghz_stats();

    return [
        'captured_at_unix_ms' => (int)round(microtime(true) * 1000),
        'current_governor' => current_cpu_governor_label(),
        'average_cpu_ghz' => $frequencyStats['average'] === null ? null : round((float)$frequencyStats['average'], 3),
        'min_cpu_ghz' => $frequencyStats['min'] === null ? null : round((float)$frequencyStats['min'], 3),
        'max_cpu_ghz' => $frequencyStats['max'] === null ? null : round((float)$frequencyStats['max'], 3),
        'c_state_time_totals_us' => cpu_c_state_time_totals_us(),
        'c_state_time_totals_us_by_package' => cpu_c_state_time_totals_us_by_package(),
    ];
}

function disks_runtime_pm_capabilities(): array
{
    return [
        'disk_runtime_pm_targets' => discover_runtime_pm_targets(['/sys/block/sd*/device/power/control']),
        'ata_runtime_pm_targets' => discover_runtime_pm_targets(['/sys/bus/pci/devices/????:??:??.?/ata*/power/control']),
        'nvme_runtime_pm_targets' => discover_runtime_pm_targets([
            '/sys/class/nvme/nvme*/device/power/control',
            '/sys/class/nvme-subsystem/nvme-subsys*/device/power/control',
            '/sys/class/nvme-fabrics/*/power/control',
            '/sys/class/nvme-fabrics/ctl/power/control',
            '/sys/class/nvme-fabrics/ctl*/power/control',
        ]),
    ];
}

function i2c_runtime_pm_capabilities(): array
{
    return [
        'i2c_runtime_pm_targets' => discover_runtime_pm_targets(['/sys/bus/i2c/devices/*/device/power/control']),
    ];
}

function constrain_runtime_pm_mode(string $mode, array $availableTargets, string $default): string
{
    if ($mode === 'disabled') {
        return 'disabled';
    }

    $targets = normalize_runtime_target_list($availableTargets);
    if (in_array($mode, $targets, true)) {
        return $mode;
    }

    if (in_array($default, $targets, true)) {
        return $default;
    }

    return $targets[0];
}

function runtime_pm_mode_from_raw(array $raw, string $modeKey, string $default): string
{
    return normalize_runtime_pm_mode($raw[$modeKey] ?? $default, $default);
}

function cpu_governor_mode_from_raw(array $raw, array $availableGovernors): string
{
    $default = in_array('powersave', $availableGovernors, true) ? 'powersave' : 'disabled';
    $mode = normalize_cpu_governor_mode($raw['CPU_GOVERNOR_MODE'] ?? $default, $default);

    if ($mode === 'disabled') {
        return 'disabled';
    }

    return in_array($mode, $availableGovernors, true) ? $mode : $default;
}

function cpu_turbo_mode_from_raw(array $raw, bool $supportsCpuTurbo): string
{
    if (!$supportsCpuTurbo) {
        return 'disabled';
    }

    return normalize_cpu_turbo_mode($raw['CPU_TURBO_MODE'] ?? 'disabled', 'disabled');
}

function pcie_settings_from_raw(array $raw): array
{
    $blacklistCsv = trim((string)($raw['BLACK_LIST'] ?? 'Example1,Example2'));
    if ($blacklistCsv === '') {
        $blacklistCsv = 'Example1,Example2';
    }

    $manualSelectedDevicesRaw = normalize_csv_items((string)($raw['MANUAL_SELECTED_DEVICES'] ?? ''));
    $forceAspmEndpointMode = normalize_force_aspm_mode(
        $raw['FORCE_ASPM_ENDPOINT_MODE'] ?? 0,
        0
    );
    $forceAspmBridgeMode = normalize_force_aspm_mode(
        $raw['FORCE_ASPM_BRIDGE_MODE'] ?? 0,
        0
    );

    $manualDeviceOptions = decode_manual_device_options((string)($raw['MANUAL_DEVICE_OPTIONS'] ?? ''));
    $selectedMap = [];

    foreach ($manualSelectedDevicesRaw as $deviceId) {
        $normalizedId = normalize_pci_device_identifier($deviceId);
        if ($normalizedId === '') {
            continue;
        }

        $selectedMap[$normalizedId] = true;
        if (!array_key_exists($normalizedId, $manualDeviceOptions)) {
            $manualDeviceOptions[$normalizedId] = default_manual_device_profile();
        }
        $manualDeviceOptions[$normalizedId]['enabled'] = 1;
    }

    foreach ($manualDeviceOptions as $deviceId => $profile) {
        $manualDeviceOptions[$deviceId] = normalize_manual_device_profile($profile);
        if ($manualDeviceOptions[$deviceId]['enabled'] === 1) {
            $selectedMap[$deviceId] = true;
        }
    }

    ksort($manualDeviceOptions, SORT_STRING);
    $manualSelectedDevices = array_keys($selectedMap);
    sort($manualSelectedDevices, SORT_STRING);

    return [
        'blacklist_csv' => $blacklistCsv,
        'auto_execute_on_startup' => normalize_boolean($raw['AUTO_EXECUTE_ON_STARTUP'] ?? null, 0),
        'operation_mode' => normalize_mode($raw['OPERATION_MODE'] ?? 'automatic', 'automatic'),
        'max_aspm_level' => normalize_aspm_level($raw['MAX_ASPM_LEVEL'] ?? 3, 3),
        'enable_aspm_optimization' => normalize_boolean($raw['ENABLE_ASPM_OPTIMIZATION'] ?? null, 1),
        'enable_clkpm_optimization' => normalize_boolean($raw['ENABLE_CLKPM_OPTIMIZATION'] ?? null, 1),
        'enable_ltr_optimization' => normalize_boolean($raw['ENABLE_LTR_OPTIMIZATION'] ?? null, 1),
        'enable_l1ss_optimization' => normalize_boolean($raw['ENABLE_L1SS_OPTIMIZATION'] ?? null, 0),
        'enable_pci_runtime_pm_optimization' => normalize_boolean($raw['ENABLE_PCI_RUNTIME_PM_OPTIMIZATION'] ?? null, 1),
        'force_aspm_endpoint_mode' => $forceAspmEndpointMode,
        'force_aspm_bridge_mode' => $forceAspmBridgeMode,
        'manual_force_incompatible' => normalize_boolean($raw['MANUAL_FORCE_INCOMPATIBLE'] ?? null, 0),
        'manual_selected_devices' => $manualSelectedDevices,
        'manual_selected_devices_csv' => implode(',', $manualSelectedDevices),
        'manual_device_options' => $manualDeviceOptions,
    ];
}

function cpu_settings_from_raw(array $raw): array
{
    $capabilities = cpu_capabilities();
    $availableGovernors = $capabilities['available_governors'];
    $governorMode = cpu_governor_mode_from_raw($raw, $availableGovernors);
    $turboMode = cpu_turbo_mode_from_raw($raw, $capabilities['supports_cpu_turbo']);

    return [
        'auto_execute_on_startup' => normalize_boolean($raw['CPU_AUTO_EXECUTE_ON_STARTUP'] ?? null, 0),
        'cpu_mode' => normalize_mode($raw['CPU_MODE'] ?? 'automatic', 'automatic'),
        'cpu_governor_mode' => $governorMode,
        'cpu_turbo_mode' => $turboMode,
        'available_governors' => $availableGovernors,
        'supports_cpu_turbo' => $capabilities['supports_cpu_turbo'],
    ];
}

function ethernet_settings_from_raw(array $raw): array
{
    return [
        'auto_execute_on_startup' => normalize_boolean($raw['ETHERNET_AUTO_EXECUTE_ON_STARTUP'] ?? null, 0),
        'ethernet_mode' => normalize_mode($raw['ETHERNET_MODE'] ?? 'automatic', 'automatic'),
        'enable_ethernet_eee_optimization' => normalize_boolean($raw['ENABLE_ETHERNET_EEE_OPTIMIZATION'] ?? null, 1),
        'ethernet_eee_target' => normalize_on_off($raw['ETHERNET_EEE_TARGET'] ?? 'on', 'on'),
        'enable_ethernet_wol_optimization' => normalize_boolean($raw['ENABLE_ETHERNET_WOL_OPTIMIZATION'] ?? null, 1),
        'ethernet_wol_target' => normalize_wol_target($raw['ETHERNET_WOL_TARGET'] ?? 'd', 'd'),
        'ethernet_manual_interfaces_csv' => implode(',', normalize_csv_items((string)($raw['ETHERNET_MANUAL_INTERFACES'] ?? ''))),
    ];
}

function disks_settings_from_raw(array $raw): array
{
    $capabilities = [
        'disk_runtime_pm_targets' => ['auto'],
        'ata_runtime_pm_targets' => ['auto'],
        'nvme_runtime_pm_targets' => ['auto'],
    ];
    $sataMode = sata_lpm_mode_from_raw($raw);
    $diskMode = normalize_disks_runtime_pm_mode(
        runtime_pm_mode_from_raw($raw, 'DISK_RUNTIME_PM_MODE', 'auto'),
        'auto'
    );
    $ataMode = normalize_disks_runtime_pm_mode(
        runtime_pm_mode_from_raw($raw, 'ATA_RUNTIME_PM_MODE', 'auto'),
        'auto'
    );
    $nvmeApstMode = normalize_nvme_apst_mode($raw['NVME_APST_MODE'] ?? 'enabled', 'enabled');
    $nvmeMode = normalize_disks_runtime_pm_mode(
        runtime_pm_mode_from_raw($raw, 'NVME_RUNTIME_PM_MODE', 'auto'),
        'auto'
    );

    return [
        'auto_execute_on_startup' => normalize_boolean($raw['DISKS_AUTO_EXECUTE_ON_STARTUP'] ?? null, 0),
        'disks_mode' => normalize_mode($raw['DISKS_MODE'] ?? 'automatic', 'automatic'),
        'sata_lpm_mode' => $sataMode,
        'disk_runtime_pm_mode' => $diskMode,
        'ata_runtime_pm_mode' => $ataMode,
        'nvme_apst_mode' => $nvmeApstMode,
        'nvme_runtime_pm_mode' => $nvmeMode,
        'disk_runtime_pm_targets' => $capabilities['disk_runtime_pm_targets'],
        'ata_runtime_pm_targets' => $capabilities['ata_runtime_pm_targets'],
        'nvme_runtime_pm_targets' => $capabilities['nvme_runtime_pm_targets'],
    ];
}

function usb_settings_from_raw(array $raw): array
{
    $deviceGlob = trim((string)($raw['USB_DEVICE_GLOB'] ?? '*'));
    if ($deviceGlob === '') {
        $deviceGlob = '*';
    }

    return [
        'auto_execute_on_startup' => normalize_boolean($raw['USB_AUTO_EXECUTE_ON_STARTUP'] ?? null, 0),
        'usb_mode' => normalize_mode($raw['USB_MODE'] ?? 'automatic', 'automatic'),
        'enable_usb_autosuspend_optimization' => normalize_boolean($raw['ENABLE_USB_AUTOSUSPEND_OPTIMIZATION'] ?? null, 1),
        'usb_runtime_pm_target' => normalize_usb_runtime_pm_target($raw['USB_RUNTIME_PM_TARGET'] ?? 'auto', 'auto'),
        'enable_usb_wakeup_optimization' => normalize_boolean($raw['ENABLE_USB_WAKEUP_OPTIMIZATION'] ?? null, 1),
        'usb_device_glob' => $deviceGlob,
    ];
}

function i2c_settings_from_raw(array $raw): array
{
    $capabilities = i2c_runtime_pm_capabilities();

    $deviceGlob = trim((string)($raw['I2C_DEVICE_GLOB'] ?? 'i2c-*'));
    if ($deviceGlob === '') {
        $deviceGlob = 'i2c-*';
    }

    $mode = constrain_runtime_pm_mode(
        runtime_pm_mode_from_raw($raw, 'I2C_RUNTIME_PM_MODE', 'on'),
        $capabilities['i2c_runtime_pm_targets'],
        'on'
    );

    return [
        'auto_execute_on_startup' => normalize_boolean($raw['I2C_AUTO_EXECUTE_ON_STARTUP'] ?? null, 0),
        'i2c_mode' => normalize_mode($raw['I2C_MODE'] ?? 'automatic', 'automatic'),
        'i2c_runtime_pm_mode' => $mode,
        'i2c_runtime_pm_targets' => $capabilities['i2c_runtime_pm_targets'],
        'i2c_device_glob' => $deviceGlob,
    ];
}

function system_tunables_settings_from_raw(array $raw): array
{
    $nmiTarget = normalize_int_range($raw['NMI_WATCHDOG_TARGET'] ?? 0, 0, 0, 1);
    $numaBalancingTarget = normalize_int_range($raw['NUMA_BALANCING_TARGET'] ?? 0, 0, 0, 1);
    $schedulerMode = power_aware_scheduler_mode_from_raw($raw);
    $vmDirtyWritebackCentisecs = normalize_int_range(
        $raw['VM_DIRTY_WRITEBACK_CENTISECS'] ?? 1500,
        1500,
        100,
        60000
    );
    $vmLaptopMode = normalize_int_range($raw['VM_LAPTOP_MODE'] ?? 5, 5, 0, 100);
    $vmDirtyExpireCentisecs = normalize_int_range(
        $raw['VM_DIRTY_EXPIRE_CENTISECS'] ?? 6000,
        6000,
        100,
        600000
    );
    $vfsCachePressure = normalize_int_range($raw['VFS_CACHE_PRESSURE'] ?? 1, 1, 1, 10000);
    $vfsCacheMaxAge = normalize_int_range($raw['VFS_CACHE_MAX_AGE'] ?? 60000, 60000, 1, 31536000);
    $zfsArcMinPercent = normalize_int_range($raw['ZFS_ARC_MIN_PERCENT'] ?? 10, 10, 0, 100);
    $zfsArcMaxPercent = normalize_int_range($raw['ZFS_ARC_MAX_PERCENT'] ?? 40, 40, 0, 100);

    if ($zfsArcMinPercent > 0 && $zfsArcMaxPercent > 0 && $zfsArcMinPercent > $zfsArcMaxPercent) {
        $zfsArcMinPercent = $zfsArcMaxPercent;
    }

    return [
        'auto_execute_on_startup' => normalize_boolean($raw['SYSTEM_AUTO_EXECUTE_ON_STARTUP'] ?? null, 0),
        'enable_audio_codec_pm_optimization' => normalize_boolean($raw['ENABLE_AUDIO_CODEC_PM_OPTIMIZATION'] ?? null, 1),
        'audio_codec_power_save_seconds' => normalize_int_range($raw['AUDIO_CODEC_POWER_SAVE_SECONDS'] ?? 1, 1, 0, 60),
        'disable_nmi_watchdog' => $nmiTarget === 0 ? 1 : 0,
        'enable_vm_writeback_timeout_optimization' => normalize_boolean($raw['ENABLE_VM_WRITEBACK_TIMEOUT_OPTIMIZATION'] ?? null, 1),
        'vm_dirty_writeback_centisecs' => $vmDirtyWritebackCentisecs,
        'vm_laptop_mode' => $vmLaptopMode,
        'vm_dirty_expire_centisecs' => $vmDirtyExpireCentisecs,
        'vfs_cache_pressure' => $vfsCachePressure,
        'vfs_cache_max_age' => $vfsCacheMaxAge,
        'enable_disk_metadata_cache_warmup' => normalize_boolean($raw['ENABLE_DISK_METADATA_CACHE_WARMUP'] ?? null, 1),
        'enable_user_share_metadata_cache_warmup' => normalize_boolean($raw['ENABLE_USER_SHARE_METADATA_CACHE_WARMUP'] ?? null, 0),
        'zfs_arc_min_percent' => $zfsArcMinPercent,
        'zfs_arc_max_percent' => $zfsArcMaxPercent,
        'power_aware_cpu_scheduler_mode' => $schedulerMode,
        'disable_numa_balancing' => $numaBalancingTarget === 0 ? 1 : 0,
    ];
}

function get_link_caps_hex(string $device): string
{
    $output = [];
    $code = 1;
    $command = 'setpci -s ' . escapeshellarg($device) . ' CAP_EXP+0c.l 2>/dev/null';
    exec($command, $output, $code);

    if ($code !== 0 || count($output) === 0) {
        return '';
    }

    $value = preg_replace('/\s+/', '', trim((string)$output[0]));
    return preg_match('/^[0-9a-fA-F]{8}$/', $value) === 1 ? $value : '';
}

function get_dev_cap2_hex(string $device): string
{
    $output = [];
    $code = 1;
    $command = 'setpci -s ' . escapeshellarg($device) . ' CAP_EXP+24.l 2>/dev/null';
    exec($command, $output, $code);

    if ($code !== 0 || count($output) === 0) {
        return '';
    }

    $value = preg_replace('/\s+/', '', trim((string)$output[0]));
    return preg_match('/^[0-9a-fA-F]{8}$/', $value) === 1 ? $value : '';
}

function get_extended_capability_offset(string $device, int $wantedId): int
{
    $position = 0x100;

    for ($hop = 0; $hop < 64 && $position >= 0x100 && $position < 0x1000; $hop++) {
        $output = [];
        $code = 1;
        $command = 'setpci -s ' . escapeshellarg($device) . ' ' . escapeshellarg(sprintf('%x.l', $position)) . ' 2>/dev/null';
        exec($command, $output, $code);

        if ($code !== 0 || count($output) === 0) {
            return -1;
        }

        $header = preg_replace('/\s+/', '', trim((string)$output[0]));
        if (preg_match('/^[0-9a-fA-F]{8}$/', $header) !== 1) {
            return -1;
        }

        $headerValue = hexdec($header);
        $capabilityId = $headerValue & 0xffff;
        $nextPosition = ($headerValue >> 20) & 0xfff;

        if ($capabilityId === $wantedId) {
            return $position;
        }

        if ($nextPosition === 0 || $nextPosition === $position) {
            break;
        }

        $position = $nextPosition;
    }

    return 0;
}

function pci_clkpm_support_state_from_caps(string $capHex): string
{
    if ($capHex === '') {
        return 'unknown';
    }

    return ((hexdec($capHex) >> 18) & 1) === 1 ? 'supported' : 'unsupported';
}

function pci_ltr_support_state(string $device): string
{
    $capHex = get_dev_cap2_hex($device);
    if ($capHex === '') {
        return 'unknown';
    }

    return ((hexdec($capHex) >> 11) & 1) === 1 ? 'supported' : 'unsupported';
}

function pci_l1ss_support_state(string $device): string
{
    $offset = get_extended_capability_offset($device, 0x1e);
    if ($offset < 0) {
        return 'unknown';
    }

    if ($offset === 0) {
        return 'unsupported';
    }

    $output = [];
    $code = 1;
    $command = 'setpci -s ' . escapeshellarg($device) . ' ' . escapeshellarg(sprintf('%x.l', $offset + 4)) . ' 2>/dev/null';
    exec($command, $output, $code);
    if ($code !== 0 || count($output) === 0) {
        return 'unknown';
    }

    $capHex = preg_replace('/\s+/', '', trim((string)$output[0]));
    if (preg_match('/^[0-9a-fA-F]{8}$/', $capHex) !== 1) {
        return 'unknown';
    }

    return (hexdec($capHex) & 0x0f) > 0 ? 'supported' : 'unsupported';
}

function pci_runtime_pm_support_state(string $device): string
{
    $normalized = normalize_pci_device_id($device);
    if ($normalized === '') {
        return 'unknown';
    }

    $path = '/sys/bus/pci/devices/' . $normalized . '/power/control';
    return is_file($path) ? 'supported' : 'unsupported';
}

function get_parent_pci_device(string $device): string
{
    $path = '/sys/bus/pci/devices/' . $device;
    $real = @realpath($path);
    if ($real === false) {
        return '';
    }

    $parent = basename(dirname($real));
    if (!preg_match('/^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$/', $parent)) {
        return '';
    }

    if (strcasecmp($parent, $device) === 0) {
        return '';
    }

    return $parent;
}

function compute_depth(string $deviceId, array $deviceMap): int
{
    $depth = 0;
    $cursor = $deviceId;
    $seen = [];

    while (isset($deviceMap[$cursor])) {
        $parent = $deviceMap[$cursor]['parent_id'] ?? '';
        if ($parent === '' || !isset($deviceMap[$parent])) {
            break;
        }

        if (isset($seen[$parent])) {
            break;
        }

        $seen[$parent] = true;
        $depth++;
        $cursor = $parent;

        if ($depth >= 32) {
            break;
        }
    }

    return $depth;
}

function build_topology_path(string $deviceId, array $deviceMap): string
{
    $path = [];
    $cursor = $deviceId;
    $seen = [];

    while (isset($deviceMap[$cursor]) && !isset($seen[$cursor])) {
        $seen[$cursor] = true;
        array_unshift($path, $cursor);

        $parent = $deviceMap[$cursor]['parent_id'] ?? '';
        if ($parent === '' || !isset($deviceMap[$parent])) {
            break;
        }

        $cursor = $parent;
        if (count($path) >= 32) {
            break;
        }
    }

    return implode(' > ', $path);
}

function aspm_support_label_from_mode(int $aspmMode): string
{
    switch ($aspmMode) {
        case 1:
            return 'L0';
        case 2:
            return 'L1';
        case 3:
            return 'L0 & L1';
        default:
            return 'unsupported';
    }
}

function get_pci_devices(bool $forceAspmEndpoints = false, bool $forceAspmBridges = false): array
{
    $lines = [];
    $code = 1;
    exec('lspci -D 2>/dev/null', $lines, $code);
    if ($code !== 0) {
        return [];
    }

    $devices = [];
    $runtimeAspmMap = get_pcie_aspm_status_map();
    foreach ($lines as $line) {
        if (!preg_match('/^([0-9a-fA-F:.]+)\s+(.+)$/', trim($line), $matches)) {
            continue;
        }

        $device = $matches[1];
        $description = $matches[2];
        $type = preg_match('/PCI bridge|Root Port/i', $description) ? 'bridge' : 'endpoint';

        $capHex = get_link_caps_hex($device);
        if ($capHex === '') {
            $aspmState = 'unknown';
            $aspmSupported = false;
        } else {
            $aspmMode = (hexdec($capHex) >> 10) & 3;
            if ($aspmMode === 0) {
                $aspmState = 'unsupported';
                $aspmSupported = false;
            } else {
                $aspmState = aspm_support_label_from_mode($aspmMode);
                $aspmSupported = true;
            }
        }

        $clkpmSupport = pci_clkpm_support_state_from_caps($capHex);
        $ltrSupport = pci_ltr_support_state($device);
        $l1ssSupport = pci_l1ss_support_state($device);
        $runtimePmSupport = pci_runtime_pm_support_state($device);

        $normalizedDeviceId = normalize_pci_device_id($device);

        $forceAspmForType = $type === 'bridge' ? $forceAspmBridges : $forceAspmEndpoints;

        $devices[] = [
            'id' => $device,
            'description' => $description,
            'type' => $type,
            'aspm_state' => $aspmState,
            'aspm_runtime' => $runtimeAspmMap[$normalizedDeviceId] ?? ($runtimeAspmMap[$device] ?? 'unknown'),
            'aspm_supported' => $aspmSupported,
            'clkpm_support' => $clkpmSupport,
            'ltr_support' => $ltrSupport,
            'l1ss_support' => $l1ssSupport,
            'runtime_pm_support' => $runtimePmSupport,
            'selectable' => $aspmSupported || $forceAspmForType,
            'parent_id' => get_parent_pci_device($device),
        ];
    }

    usort($devices, static function (array $left, array $right): int {
        return strcmp($left['id'], $right['id']);
    });

    $deviceMap = [];
    foreach ($devices as $device) {
        $deviceMap[$device['id']] = $device;
    }

    foreach ($devices as &$device) {
        $device['topology_path'] = build_topology_path($device['id'], $deviceMap);
    }
    unset($device);

    return $devices;
}

function normalize_pci_device_id(string $device): string
{
    $normalized = strtolower(trim($device));

    if (preg_match('/^[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$/', $normalized) === 1) {
        return '0000:' . $normalized;
    }

    if (preg_match('/^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$/', $normalized) === 1) {
        return $normalized;
    }

    return $normalized;
}

function normalize_aspm_runtime_segment(string $value): string
{
    $normalized = trim((string)preg_replace('/\s+/', ' ', $value));
    if ($normalized === '') {
        return '';
    }

    $hasL0s = preg_match('/\bL0s?\b/i', $normalized) === 1;
    $hasL1 = preg_match('/\bL1\b/i', $normalized) === 1;

    if ($hasL0s && $hasL1) {
        return 'L0s & L1';
    }

    if ($hasL0s) {
        return 'L0s';
    }

    if ($hasL1) {
        return 'L1';
    }

    if (preg_match('/\bdisabled\b/i', $normalized) === 1) {
        return 'disabled';
    }

    $normalized = (string)preg_replace('/\benabled\b/i', '', $normalized);
    return trim((string)preg_replace('/\s+/', ' ', $normalized));
}

function simplify_aspm_runtime_text(string $line): string
{
    $trimmed = trim($line);
    if ($trimmed === '') {
        return '';
    }

    if (preg_match('/ASPM\s+([^;]+)/i', $trimmed, $matches) === 1) {
        return normalize_aspm_runtime_segment($matches[1]);
    }

    return normalize_aspm_runtime_segment($trimmed);
}

function get_pcie_aspm_status_map(): array
{
    $output = [];
    $code = 1;
    $command = 'lspci -D -vv 2>/dev/null';
    exec($command, $output, $code);

    if ($code !== 0 || count($output) === 0) {
        return [];
    }

    $map = [];
    $currentDevice = '';
    $currentPreferredLine = '';
    $currentFallbackLine = '';

    $flushCurrent = static function () use (&$map, &$currentDevice, &$currentPreferredLine, &$currentFallbackLine): void {
        if ($currentDevice === '') {
            return;
        }

        $selectedLine = $currentPreferredLine !== '' ? $currentPreferredLine : $currentFallbackLine;
        $simplifiedLine = simplify_aspm_runtime_text($selectedLine);
        if ($simplifiedLine !== '' && !isset($map[$currentDevice])) {
            $map[$currentDevice] = $simplifiedLine;
        }
    };

    foreach ($output as $line) {
        $trimmed = trim($line);
        if (preg_match('/^([0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7])\s+/', $trimmed, $matches)) {
            $flushCurrent();
            $currentDevice = normalize_pci_device_id($matches[1]);
            $currentPreferredLine = '';
            $currentFallbackLine = '';
            continue;
        }

        if ($currentDevice === '' || $trimmed === '' || stripos($trimmed, 'ASPM') === false) {
            continue;
        }

        if ($currentFallbackLine === '') {
            $currentFallbackLine = $trimmed;
        }

        if ($currentPreferredLine === '' && stripos($trimmed, 'LnkCtl:') !== false) {
            $currentPreferredLine = $trimmed;
        }
    }

    $flushCurrent();

    return $map;
}

function append_kernel_params_to_append_line(string $line, array $params): string
{
    if (!preg_match('/^(\s*append\s+)(.*)$/i', $line, $matches)) {
        return $line;
    }

    $prefix = $matches[1];
    $rest = trim($matches[2]);

    foreach ($params as $param) {
        if (!preg_match('/(^|\s)' . preg_quote($param, '/') . '($|\s)/', $rest)) {
            $rest = trim($rest . ' ' . $param);
        }
    }

    return $prefix . $rest;
}

function update_label_append_params(array &$lines, string $label, array $params, bool &$changed): bool
{
    for ($i = 0; $i < count($lines); $i++) {
        if (!preg_match('/^\s*label\s+' . preg_quote($label, '/') . '\s*$/i', $lines[$i])) {
            continue;
        }

        for ($j = $i + 1; $j < count($lines); $j++) {
            if (preg_match('/^\s*label\s+/i', $lines[$j])) {
                break;
            }

            if (preg_match('/^\s*append\s+/i', $lines[$j])) {
                $updated = append_kernel_params_to_append_line($lines[$j], $params);
                if ($updated !== $lines[$j]) {
                    $lines[$j] = $updated;
                    $changed = true;
                }
                return true;
            }
        }

        return true;
    }

    return false;
}

function edit_syslinux_aspm_config(string $syslinuxFile): array
{
    if (!is_file($syslinuxFile)) {
        return ['ok' => false, 'message' => 'Syslinux configuration file not found: ' . $syslinuxFile];
    }

    $raw = file_get_contents($syslinuxFile);
    if ($raw === false) {
        return ['ok' => false, 'message' => 'Failed to read syslinux configuration.'];
    }

    $eol = strpos($raw, "\r\n") !== false ? "\r\n" : "\n";
    $lines = preg_split('/\r\n|\n|\r/', $raw);
    if (!is_array($lines)) {
        return ['ok' => false, 'message' => 'Failed to parse syslinux configuration.'];
    }

    $params = [
        'pcie_aspm=force',
        'pcie_aspm.policy=powersupersave',
        'pcie_port_pm=force',
    ];

    $changed = false;
    $missingLabels = [];
    foreach (['Unraid OS', 'Unraid OS GUI Mode'] as $label) {
        $found = update_label_append_params($lines, $label, $params, $changed);
        if (!$found) {
            $missingLabels[] = $label;
        }
    }

    if (count($missingLabels) === 2) {
        return ['ok' => false, 'message' => 'Could not find Unraid OS boot labels in syslinux.cfg.'];
    }

    if ($changed) {
        $backupFile = $syslinuxFile . '.bak';
        if (!is_file($backupFile)) {
            @copy($syslinuxFile, $backupFile);
        }

        $updatedRaw = implode($eol, $lines);
        if (substr($raw, -strlen($eol)) === $eol) {
            $updatedRaw .= $eol;
        }

        if (file_put_contents($syslinuxFile, $updatedRaw, LOCK_EX) === false) {
            return ['ok' => false, 'message' => 'Failed to update syslinux configuration.'];
        }
    }

    $message = $changed
        ? 'Syslinux updated with ASPM kernel parameters. Reboot to apply changes.'
        : 'Syslinux already contained required ASPM kernel parameters.';

    if (count($missingLabels) > 0) {
        $message .= ' Missing labels: ' . implode(', ', $missingLabels) . '.';
    }

    return ['ok' => true, 'message' => $message];
}

function send_unraid_notification(string $notifyScript, string $event, string $icon, string $subject, string $message): bool
{
    if (!is_executable($notifyScript)) {
        return false;
    }

    $command = sprintf(
        '%s -e %s -i %s -s %s -d %s >/dev/null 2>&1',
        escapeshellarg($notifyScript),
        escapeshellarg($event),
        escapeshellarg($icon),
        escapeshellarg($subject),
        escapeshellarg($message)
    );

    exec($command);
    return true;
}

function run_in_background(string $command, string $logFile): void
{
    if (!is_dir(dirname($logFile))) {
        @mkdir(dirname($logFile), 0775, true);
    }

    $wrapped = sprintf('nohup %s >> %s 2>&1 &', $command, escapeshellarg($logFile));
    exec($wrapped);
}

function read_log_tail(string $logFile, int $maxLines = 200): string
{
    if (!is_file($logFile)) {
        return '';
    }

    $lines = @file($logFile, FILE_IGNORE_NEW_LINES);
    if ($lines === false || count($lines) === 0) {
        return '';
    }

    $tail = array_slice($lines, -$maxLines);
    $output = implode("\n", $tail);

    // Strip basic ANSI color/control sequences for cleaner web output.
    return (string)preg_replace('/\x1b\[[0-9;]*[A-Za-z]/', '', $output);
}

function resolve_log_file_by_scope(string $scope, string $logBaseDir): ?string
{
    $normalized = strtolower(trim($scope));
    $map = [
        'pcie' => 'power.optimizer-pcie.log',
        'cpu' => 'power.optimizer-cpu.log',
        'ethernet' => 'power.optimizer-ethernet.log',
        'disks' => 'power.optimizer-disks.log',
        'usb' => 'power.optimizer-usb.log',
        'i2c' => 'power.optimizer-i2c.log',
        'system' => 'power.optimizer-system-tunables.log',
        'system-tunables' => 'power.optimizer-system-tunables.log',
    ];

    if (!array_key_exists($normalized, $map)) {
        return null;
    }

    return $logBaseDir . '/' . $map[$normalized];
}

$action = $_POST['action'] ?? $_GET['action'] ?? '';
$defaults = default_settings();
$rawSettings = read_raw_settings($configFile, $defaults);

if ($action === 'get_execution_log_output') {
    $scope = (string)($_POST['scope'] ?? $_GET['scope'] ?? '');
    $logFile = resolve_log_file_by_scope($scope, $logBaseDir);

    if ($logFile === null) {
        send_json(422, ['ok' => false, 'message' => 'Invalid log scope.']);
    }

    $requestedLines = normalize_int_range($_POST['lines'] ?? $_GET['lines'] ?? 200, 200, 20, 500);
    send_json(200, [
        'ok' => true,
        'scope' => strtolower(trim($scope)),
        'log' => $logFile,
        'output' => read_log_tail($logFile, $requestedLines),
    ]);
}

if ($action === 'get_status') {
    send_json(200, [
        'ok' => true,
        'settings' => pcie_settings_from_raw($rawSettings),
    ]);
}

if ($action === 'save_settings') {
    $blacklistItems = normalize_csv_items((string)($_POST['blacklist'] ?? ''));
    if (count($blacklistItems) === 0) {
        send_json(422, ['ok' => false, 'message' => 'BLACK_LIST cannot be empty. Add at least one pattern.']);
    }

    $forceAspmEndpointMode = normalize_force_aspm_mode($_POST['force_aspm_endpoint_mode'] ?? 0, 0);
    $forceAspmBridgeMode = normalize_force_aspm_mode($_POST['force_aspm_bridge_mode'] ?? 0, 0);

    $manualDeviceOptions = normalize_manual_device_options_from_post((string)($_POST['manual_device_options'] ?? ''));

    $manualSelectedDevices = [];
    foreach ($manualDeviceOptions as $deviceId => $profile) {
        $manualDeviceOptions[$deviceId] = normalize_manual_device_profile($profile);
        if ($manualDeviceOptions[$deviceId]['enabled'] === 1) {
            $manualSelectedDevices[] = $deviceId;
        }
    }
    sort($manualSelectedDevices, SORT_STRING);

    $manualSelectedDevicesCsv = implode(',', $manualSelectedDevices);
    $manualDeviceOptionsRaw = encode_manual_device_options($manualDeviceOptions);

    $updates = [
        'BLACK_LIST' => implode(',', $blacklistItems),
        'AUTO_EXECUTE_ON_STARTUP' => (string)normalize_boolean($_POST['auto_execute_on_startup'] ?? null, 0),
        'OPERATION_MODE' => normalize_mode($_POST['operation_mode'] ?? 'automatic', 'automatic'),
        'MAX_ASPM_LEVEL' => (string)normalize_aspm_level($_POST['max_aspm_level'] ?? 3, 3),
        'ENABLE_ASPM_OPTIMIZATION' => (string)normalize_boolean($_POST['enable_aspm_optimization'] ?? null, 1),
        'ENABLE_CLKPM_OPTIMIZATION' => (string)normalize_boolean($_POST['enable_clkpm_optimization'] ?? null, 1),
        'ENABLE_LTR_OPTIMIZATION' => (string)normalize_boolean($_POST['enable_ltr_optimization'] ?? null, 1),
        'ENABLE_L1SS_OPTIMIZATION' => (string)normalize_boolean($_POST['enable_l1ss_optimization'] ?? null, 0),
        'ENABLE_PCI_RUNTIME_PM_OPTIMIZATION' => (string)normalize_boolean($_POST['enable_pci_runtime_pm_optimization'] ?? null, 1),
        'FORCE_ASPM_ENDPOINT_MODE' => (string)$forceAspmEndpointMode,
        'FORCE_ASPM_BRIDGE_MODE' => (string)$forceAspmBridgeMode,
        'MANUAL_FORCE_INCOMPATIBLE' => (string)normalize_boolean($_POST['manual_force_incompatible'] ?? null, 0),
        'MANUAL_SELECTED_DEVICES' => $manualSelectedDevicesCsv,
        'MANUAL_DEVICE_OPTIONS' => $manualDeviceOptionsRaw,
    ];

    if ($updates['OPERATION_MODE'] === 'manual' && $updates['MANUAL_SELECTED_DEVICES'] === '') {
        send_json(422, ['ok' => false, 'message' => 'Manual mode requires at least one selected PCI device.']);
    }

    $updatedRaw = array_merge($rawSettings, $updates);
    if (!write_raw_settings($configDir, $configFile, $defaults, $updatedRaw)) {
        send_json(500, ['ok' => false, 'message' => 'Failed to write settings.cfg.']);
    }

    send_json(200, [
        'ok' => true,
        'message' => 'PCI Express settings saved.',
        'settings' => pcie_settings_from_raw($updatedRaw),
    ]);
}

if ($action === 'get_devices') {
    $pcie = pcie_settings_from_raw($rawSettings);
    $forceAspmEndpointMode = normalize_force_aspm_mode(
        $_POST['force_aspm_endpoint_mode'] ?? null,
        (int)($pcie['force_aspm_endpoint_mode'] ?? 0)
    );

    $forceAspmBridgeMode = normalize_force_aspm_mode(
        $_POST['force_aspm_bridge_mode'] ?? null,
        (int)($pcie['force_aspm_bridge_mode'] ?? 0)
    );

    send_json(200, [
        'ok' => true,
        'devices' => get_pci_devices($forceAspmEndpointMode !== 0, $forceAspmBridgeMode !== 0),
    ]);
}

if ($action === 'edit_syslinux_aspm') {
    $result = edit_syslinux_aspm_config($syslinuxFile);
    $notificationSent = send_unraid_notification(
        $notifyScript,
        $pluginName,
        $result['ok'] ? 'normal' : 'alert',
        $result['ok'] ? 'Syslinux ASPM update complete' : 'Syslinux ASPM update failed',
        (string)($result['message'] ?? '')
    );
    $result['notification_sent'] = $notificationSent;
    send_json($result['ok'] ? 200 : 500, $result);
}

if ($action === 'run_auto_optimize') {
    if (!is_executable($pcieScriptFile)) {
        send_json(500, ['ok' => false, 'message' => 'PCIe optimizer script is missing or not executable.', 'script' => $pcieScriptFile]);
    }

    $logFile = $logBaseDir . '/power.optimizer-pcie.log';
    run_in_background('/bin/bash ' . escapeshellarg($pcieScriptFile) . ' auto-optimize', $logFile);

    send_json(200, [
        'ok' => true,
        'message' => 'PCIe optimization started.',
        'log' => $logFile,
    ]);
}

if ($action === 'get_cpu_settings') {
    send_json(200, [
        'ok' => true,
        'settings' => cpu_settings_from_raw($rawSettings),
        'capabilities' => cpu_capabilities(),
    ]);
}

if ($action === 'get_cpu_live_statistics') {
    send_json(200, [
        'ok' => true,
        'stats' => cpu_live_statistics(),
    ]);
}

if ($action === 'save_cpu_settings') {
    $cpuCapabilities = cpu_capabilities();
    $availableGovernors = $cpuCapabilities['available_governors'];
    $governorDefault = in_array('powersave', $availableGovernors, true)
        ? 'powersave'
        : (count($availableGovernors) > 0 ? $availableGovernors[0] : 'disabled');

    $requestedGovernorMode = normalize_cpu_governor_mode(
        $_POST['cpu_governor_mode'] ?? $governorDefault,
        $governorDefault
    );

    if ($requestedGovernorMode !== 'disabled' && !in_array($requestedGovernorMode, $availableGovernors, true)) {
        $requestedGovernorMode = $governorDefault;
    }

    if ($requestedGovernorMode !== 'disabled' && !in_array($requestedGovernorMode, $availableGovernors, true)) {
        $requestedGovernorMode = 'disabled';
    }

    $requestedTurboMode = normalize_cpu_turbo_mode($_POST['cpu_turbo_mode'] ?? 'disabled', 'disabled');
    if (!$cpuCapabilities['supports_cpu_turbo']) {
        $requestedTurboMode = 'disabled';
    }

    $updates = [
        'CPU_MODE' => 'automatic',
        'CPU_AUTO_EXECUTE_ON_STARTUP' => (string)normalize_boolean($_POST['auto_execute_on_startup'] ?? null, 0),
        'CPU_GOVERNOR_MODE' => $requestedGovernorMode,
        'CPU_TURBO_MODE' => $requestedTurboMode,
    ];

    $updatedRaw = array_merge($rawSettings, $updates);
    if (!write_raw_settings($configDir, $configFile, $defaults, $updatedRaw)) {
        send_json(500, ['ok' => false, 'message' => 'Failed to save CPU settings.']);
    }

    send_json(200, [
        'ok' => true,
        'message' => 'CPU settings saved.',
        'settings' => cpu_settings_from_raw($updatedRaw),
        'capabilities' => cpu_capabilities(),
    ]);
}

if ($action === 'run_cpu_optimization') {
    if (!is_executable($cpuScriptFile)) {
        send_json(500, ['ok' => false, 'message' => 'CPU optimizer script is missing or not executable.', 'script' => $cpuScriptFile]);
    }

    $logFile = $logBaseDir . '/power.optimizer-cpu.log';
    run_in_background('/bin/bash ' . escapeshellarg($cpuScriptFile), $logFile);
    send_json(200, ['ok' => true, 'message' => 'CPU optimization started.', 'log' => $logFile]);
}

if ($action === 'get_ethernet_settings') {
    send_json(200, ['ok' => true, 'settings' => ethernet_settings_from_raw($rawSettings)]);
}

if ($action === 'save_ethernet_settings') {
    $wolEnable = (string)normalize_boolean($_POST['enable_ethernet_wol_optimization'] ?? null, 1);
    $wolTarget = 'd';
    $ethernetMode = 'automatic';
    $manualInterfacesCsv = '';

    $updates = [
        'ETHERNET_AUTO_EXECUTE_ON_STARTUP' => (string)normalize_boolean($_POST['auto_execute_on_startup'] ?? null, 0),
        'ETHERNET_MODE' => $ethernetMode,
        'ENABLE_ETHERNET_EEE_OPTIMIZATION' => (string)normalize_boolean($_POST['enable_ethernet_eee_optimization'] ?? null, 1),
        'ETHERNET_EEE_TARGET' => 'on',
        'ENABLE_ETHERNET_WOL_OPTIMIZATION' => $wolEnable,
        'ETHERNET_WOL_TARGET' => $wolTarget,
        'ETHERNET_MANUAL_INTERFACES' => $manualInterfacesCsv,
    ];

    $updatedRaw = array_merge($rawSettings, $updates);
    if (!write_raw_settings($configDir, $configFile, $defaults, $updatedRaw)) {
        send_json(500, ['ok' => false, 'message' => 'Failed to save Ethernet settings.']);
    }

    send_json(200, ['ok' => true, 'message' => 'Ethernet settings saved.', 'settings' => ethernet_settings_from_raw($updatedRaw)]);
}

if ($action === 'run_ethernet_optimization') {
    if (!is_executable($ethernetScriptFile)) {
        send_json(500, ['ok' => false, 'message' => 'Ethernet optimizer script is missing or not executable.', 'script' => $ethernetScriptFile]);
    }

    $logFile = $logBaseDir . '/power.optimizer-ethernet.log';
    run_in_background('/bin/bash ' . escapeshellarg($ethernetScriptFile), $logFile);
    send_json(200, ['ok' => true, 'message' => 'Ethernet optimization started.', 'log' => $logFile]);
}

if ($action === 'get_disks_settings') {
    send_json(200, [
        'ok' => true,
        'settings' => disks_settings_from_raw($rawSettings),
        'capabilities' => disks_runtime_pm_capabilities(),
    ]);
}

if ($action === 'save_disks_settings') {
    $sataMode = normalize_sata_lpm_mode($_POST['sata_lpm_mode'] ?? 'min_power', 'min_power');
    $diskMode = normalize_disks_runtime_pm_mode($_POST['disk_runtime_pm_mode'] ?? 'auto', 'auto');
    $ataMode = normalize_disks_runtime_pm_mode($_POST['ata_runtime_pm_mode'] ?? 'auto', 'auto');
    $nvmeApstMode = normalize_nvme_apst_mode($_POST['nvme_apst_mode'] ?? 'enabled', 'enabled');
    $nvmeMode = normalize_disks_runtime_pm_mode($_POST['nvme_runtime_pm_mode'] ?? 'auto', 'auto');

    $updates = [
        'DISKS_MODE' => 'automatic',
        'DISKS_AUTO_EXECUTE_ON_STARTUP' => (string)normalize_boolean($_POST['auto_execute_on_startup'] ?? null, 0),
        'SATA_LPM_MODE' => $sataMode,
        'DISK_RUNTIME_PM_MODE' => $diskMode,
        'ATA_RUNTIME_PM_MODE' => $ataMode,
        'NVME_APST_MODE' => $nvmeApstMode,
        'NVME_RUNTIME_PM_MODE' => $nvmeMode,
    ];

    $updatedRaw = array_merge($rawSettings, $updates);
    if (!write_raw_settings($configDir, $configFile, $defaults, $updatedRaw)) {
        send_json(500, ['ok' => false, 'message' => 'Failed to save Disks settings.']);
    }

    send_json(200, [
        'ok' => true,
        'message' => 'Disks settings saved.',
        'settings' => disks_settings_from_raw($updatedRaw),
        'capabilities' => disks_runtime_pm_capabilities(),
    ]);
}

if ($action === 'run_disks_optimization') {
    if (!is_executable($disksScriptFile)) {
        send_json(500, ['ok' => false, 'message' => 'Disks optimizer script is missing or not executable.', 'script' => $disksScriptFile]);
    }

    $logFile = $logBaseDir . '/power.optimizer-disks.log';
    run_in_background('/bin/bash ' . escapeshellarg($disksScriptFile), $logFile);
    send_json(200, ['ok' => true, 'message' => 'Disks optimization started.', 'log' => $logFile]);
}

if ($action === 'run_disks_spin_down_all') {
    if (!is_file($disksSpinDownScriptFile)) {
        send_json(500, ['ok' => false, 'message' => 'Disks spin-down script is missing.', 'script' => $disksSpinDownScriptFile]);
    }

    $logFile = $logBaseDir . '/power.optimizer-disks.log';
    run_in_background('/bin/bash ' . escapeshellarg($disksSpinDownScriptFile), $logFile);
    send_json(200, ['ok' => true, 'message' => 'Spin down requested for all /dev/sd? devices.', 'log' => $logFile]);
}

if ($action === 'get_usb_settings') {
    send_json(200, ['ok' => true, 'settings' => usb_settings_from_raw($rawSettings)]);
}

if ($action === 'save_usb_settings') {
    $deviceGlob = trim((string)($_POST['usb_device_glob'] ?? '*'));
    if ($deviceGlob === '') {
        $deviceGlob = '*';
    }

    $enableUsbWakeupOptimization = normalize_boolean($_POST['enable_usb_wakeup_optimization'] ?? null, 1);

    $updates = [
        'USB_MODE' => 'automatic',
        'USB_AUTO_EXECUTE_ON_STARTUP' => (string)normalize_boolean($_POST['auto_execute_on_startup'] ?? null, 0),
        'ENABLE_USB_AUTOSUSPEND_OPTIMIZATION' => (string)normalize_boolean($_POST['enable_usb_autosuspend_optimization'] ?? null, 1),
        'USB_RUNTIME_PM_TARGET' => normalize_usb_runtime_pm_target($_POST['usb_runtime_pm_target'] ?? 'auto', 'auto'),
        'ENABLE_USB_WAKEUP_OPTIMIZATION' => (string)$enableUsbWakeupOptimization,
        'USB_WAKEUP_TARGET' => 'disabled',
        'USB_DEVICE_GLOB' => $deviceGlob,
    ];

    $updatedRaw = array_merge($rawSettings, $updates);
    if (!write_raw_settings($configDir, $configFile, $defaults, $updatedRaw)) {
        send_json(500, ['ok' => false, 'message' => 'Failed to save USB settings.']);
    }

    send_json(200, ['ok' => true, 'message' => 'USB settings saved.', 'settings' => usb_settings_from_raw($updatedRaw)]);
}

if ($action === 'run_usb_optimization') {
    if (!is_executable($usbScriptFile)) {
        send_json(500, ['ok' => false, 'message' => 'USB optimizer script is missing or not executable.', 'script' => $usbScriptFile]);
    }

    $logFile = $logBaseDir . '/power.optimizer-usb.log';
    run_in_background('/bin/bash ' . escapeshellarg($usbScriptFile), $logFile);
    send_json(200, ['ok' => true, 'message' => 'USB optimization started.', 'log' => $logFile]);
}

if ($action === 'get_i2c_settings') {
    send_json(200, [
        'ok' => true,
        'settings' => i2c_settings_from_raw($rawSettings),
        'capabilities' => i2c_runtime_pm_capabilities(),
    ]);
}

if ($action === 'save_i2c_settings') {
    $i2cCapabilities = i2c_runtime_pm_capabilities();

    $deviceGlob = trim((string)($_POST['i2c_device_glob'] ?? 'i2c-*'));
    if ($deviceGlob === '') {
        $deviceGlob = 'i2c-*';
    }

    $i2cMode = constrain_runtime_pm_mode(
        normalize_runtime_pm_mode($_POST['i2c_runtime_pm_mode'] ?? 'on', 'on'),
        $i2cCapabilities['i2c_runtime_pm_targets'],
        'on'
    );

    $updates = [
        'I2C_MODE' => 'automatic',
        'I2C_AUTO_EXECUTE_ON_STARTUP' => (string)normalize_boolean($_POST['auto_execute_on_startup'] ?? null, 0),
        'I2C_RUNTIME_PM_MODE' => $i2cMode,
        'I2C_DEVICE_GLOB' => $deviceGlob,
    ];

    $updatedRaw = array_merge($rawSettings, $updates);
    if (!write_raw_settings($configDir, $configFile, $defaults, $updatedRaw)) {
        send_json(500, ['ok' => false, 'message' => 'Failed to save I2C settings.']);
    }

    send_json(200, [
        'ok' => true,
        'message' => 'I2C settings saved.',
        'settings' => i2c_settings_from_raw($updatedRaw),
        'capabilities' => i2c_runtime_pm_capabilities(),
    ]);
}

if ($action === 'run_i2c_optimization') {
    if (!is_executable($i2cScriptFile)) {
        send_json(500, ['ok' => false, 'message' => 'I2C optimizer script is missing or not executable.', 'script' => $i2cScriptFile]);
    }

    $logFile = $logBaseDir . '/power.optimizer-i2c.log';
    run_in_background('/bin/bash ' . escapeshellarg($i2cScriptFile), $logFile);
    send_json(200, ['ok' => true, 'message' => 'I2C optimization started.', 'log' => $logFile]);
}

if ($action === 'get_system_tunables_settings') {
    send_json(200, ['ok' => true, 'settings' => system_tunables_settings_from_raw($rawSettings)]);
}

if ($action === 'save_system_tunables_settings') {
    $disableNmiWatchdog = normalize_boolean($_POST['disable_nmi_watchdog'] ?? null, 1);

    $schedulerMode = normalize_power_aware_scheduler_mode(
        $_POST['power_aware_cpu_scheduler_mode'] ?? 2,
        2
    );

    $vmWritebackEnabled = normalize_boolean($_POST['enable_vm_writeback_timeout_optimization'] ?? null, 1);
    $vmDirtyWritebackCentisecs = normalize_int_range(
        $_POST['vm_dirty_writeback_centisecs'] ?? 1500,
        1500,
        100,
        60000
    );
    $vmLaptopMode = normalize_int_range($_POST['vm_laptop_mode'] ?? 5, 5, 0, 100);
    $vmDirtyExpireCentisecs = normalize_int_range(
        $_POST['vm_dirty_expire_centisecs'] ?? 6000,
        6000,
        100,
        600000
    );
    $disableNumaBalancing = normalize_boolean($_POST['disable_numa_balancing'] ?? null, 1) === 1;
    $numaBalancingTarget = $disableNumaBalancing ? 0 : 1;
    $vfsCachePressure = normalize_int_range($_POST['vfs_cache_pressure'] ?? 1, 1, 1, 10000);
    $vfsCacheMaxAge = normalize_int_range($_POST['vfs_cache_max_age'] ?? 60000, 60000, 1, 31536000);
    $zfsArcMinPercent = normalize_int_range($_POST['zfs_arc_min_percent'] ?? 10, 10, 0, 100);
    $zfsArcMaxPercent = normalize_int_range($_POST['zfs_arc_max_percent'] ?? 40, 40, 0, 100);

    if ($zfsArcMinPercent > 0 && $zfsArcMaxPercent > 0 && $zfsArcMinPercent > $zfsArcMaxPercent) {
        $zfsArcMinPercent = $zfsArcMaxPercent;
    }

    $updates = [
        'SYSTEM_AUTO_EXECUTE_ON_STARTUP' => (string)normalize_boolean($_POST['auto_execute_on_startup'] ?? null, 0),
        'ENABLE_AUDIO_CODEC_PM_OPTIMIZATION' => (string)normalize_boolean($_POST['enable_audio_codec_pm_optimization'] ?? null, 1),
        'AUDIO_CODEC_POWER_SAVE_SECONDS' => (string)normalize_int_range($_POST['audio_codec_power_save_seconds'] ?? 1, 1, 0, 60),
        'ENABLE_NMI_WATCHDOG_OPTIMIZATION' => '1',
        'NMI_WATCHDOG_TARGET' => $disableNmiWatchdog ? '0' : '1',
        'ENABLE_VM_WRITEBACK_TIMEOUT_OPTIMIZATION' => (string)$vmWritebackEnabled,
        'VM_DIRTY_WRITEBACK_CENTISECS' => (string)$vmDirtyWritebackCentisecs,
        'VM_LAPTOP_MODE' => (string)$vmLaptopMode,
        'VM_DIRTY_EXPIRE_CENTISECS' => (string)$vmDirtyExpireCentisecs,
        'NUMA_BALANCING_TARGET' => (string)$numaBalancingTarget,
        'VFS_CACHE_PRESSURE' => (string)$vfsCachePressure,
        'VFS_CACHE_MAX_AGE' => (string)$vfsCacheMaxAge,
        'ENABLE_DISK_METADATA_CACHE_WARMUP' => (string)normalize_boolean($_POST['enable_disk_metadata_cache_warmup'] ?? null, 1),
        'ENABLE_USER_SHARE_METADATA_CACHE_WARMUP' => (string)normalize_boolean($_POST['enable_user_share_metadata_cache_warmup'] ?? null, 0),
        'ZFS_ARC_MIN_PERCENT' => (string)$zfsArcMinPercent,
        'ZFS_ARC_MAX_PERCENT' => (string)$zfsArcMaxPercent,
        'POWER_AWARE_CPU_SCHEDULER_MODE' => (string)$schedulerMode,
    ];

    $updatedRaw = array_merge($rawSettings, $updates);
    if (!write_raw_settings($configDir, $configFile, $defaults, $updatedRaw)) {
        send_json(500, ['ok' => false, 'message' => 'Failed to save System Tunables settings.']);
    }

    send_json(200, ['ok' => true, 'message' => 'System Tunables settings saved.', 'settings' => system_tunables_settings_from_raw($updatedRaw)]);
}

if ($action === 'run_system_tunables_optimization') {
    if (!is_executable($systemTunablesScriptFile)) {
        send_json(500, ['ok' => false, 'message' => 'System Tunables script is missing or not executable.', 'script' => $systemTunablesScriptFile]);
    }

    $logFile = $logBaseDir . '/power.optimizer-system-tunables.log';
    run_in_background('/bin/bash ' . escapeshellarg($systemTunablesScriptFile), $logFile);
    send_json(200, ['ok' => true, 'message' => 'System Tunables optimization started.', 'log' => $logFile]);
}

send_json(400, ['ok' => false, 'message' => 'Unknown action.']);
