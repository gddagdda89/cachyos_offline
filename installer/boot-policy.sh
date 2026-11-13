#!/usr/bin/env bash
# Pure validation shared by the installer and regression tests.
validate_coexistence_boot() {
    local firmware=$1 table=$2 has_bios_boot=$3 esp_count=$4
    if [[ $firmware == uefi ]]; then
        (( esp_count == 1 )) || {
            echo 'UEFI 共存需要所选磁盘上恰好一个 FAT32 ESP；多个 ESP 或跨盘 ESP 请手动处理。' >&2
            return 1
        }
    else
        # BIOS + ESP usually means an existing UEFI installation: fail before formatting.
        (( esp_count == 0 )) || {
            echo '当前以 BIOS 模式启动，但磁盘存在 ESP。请以 UEFI 模式重新启动安装介质。' >&2
            return 1
        }
        if [[ $table == gpt && $has_bios_boot != yes ]]; then
            echo 'BIOS + GPT 共存需要已有 BIOS boot 分区；本模式不会改动分区表。' >&2
            return 1
        fi
        [[ $table == gpt || $table == dos ]] || {
            echo '不支持的分区表类型' >&2; return 1;
        }
    fi
}
