#!/bin/bash
set -e  # 當腳本發生錯誤時立即退出
set -u  # 使用未設置的變數時退出

# 系統函式：顯示幫助
function sys_show_help() {
    cat << EOF
Usage: $(basename "$0") [options]

Options:
  -h, --help                Show this help message and exit.
  --restart NAMESPACE       Restart the StatefulSets in the specified namespace.
  --scale NAMESPACE NUMBER  Scale the StatefulSets in the specified namespace to the given number of replicas.
  --failover NAMESPACE      Perform a failover operation on the specified namespace (sentinel mode only).
  --who-is-master NAMESPACE Find out the current master node in the specified namespace (sentinel mode only).

Description:
  This script manages Kubernetes StatefulSets (STS) for Redis. It supports restarting, scaling, performing failover,
  and identifying the current master node for Redis StatefulSets dynamically based on their modes ('sentinel' or 'standalone').

Restrictions:
  The namespace 'redis' is restricted. No operations can be performed on it.

Examples:
  ./operation.sh --help
  ./operation.sh --restart redis-i1
  ./operation.sh --scale redis-i1 2
  ./operation.sh --failover redis-i1
  ./operation.sh --who-is-master redis-i1
EOF
}

# 系統函式：檢查 namespace 是否為 'redis'
function sys_validate_namespace() {
    local namespace="$1"
    if [[ "$namespace" == "redis" ]]; then
        echo "錯誤: 禁止對 'redis' namespace 執行任何操作。" >&2
        exit 1
    fi
}

# 系統函式：解析命令行參數
function sys_parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                sys_show_help
                exit 0
                ;;
            --restart)
                if [[ -n "${2:-}" ]]; then
                    sys_validate_namespace "$2"
                    redis_namespace="$2"
                    redis_mode=$(sys_detect_redis_mode "$redis_namespace")
                    sys_print_execution_details "$redis_namespace" "$redis_mode" "restart"
                    job_restart "$redis_namespace"
                    shift 2
                else
                    echo "Error: --restart 需要提供 namespace。" >&2
                    exit 1
                fi
                ;;
            --scale)
                if [[ -n "${2:-}" && -n "${3:-}" ]]; then
                    sys_validate_namespace "$2"
                    redis_namespace="$2"
                    redis_mode=$(sys_detect_redis_mode "$redis_namespace")
                    sys_print_execution_details "$redis_namespace" "$redis_mode" "scale"
                    job_scale "$redis_namespace" "$3"
                    shift 3
                else
                    echo "Error: --scale 需要提供 namespace 和數字。" >&2
                    exit 1
                fi
                ;;
            --failover)
                if [[ -n "${2:-}" ]]; then
                    sys_validate_namespace "$2"
                    redis_namespace="$2"
                    redis_mode=$(sys_detect_redis_mode "$redis_namespace")
                    sys_print_execution_details "$redis_namespace" "$redis_mode" "failover"
                    job_failover "$redis_namespace"
                    shift 2
                else
                    echo "Error: --failover 需要提供 namespace。" >&2
                    exit 1
                fi
                ;;
            --who-is-master)
                if [[ -n "${2:-}" ]]; then
                    sys_validate_namespace "$2"
                    redis_namespace="$2"
                    redis_mode=$(sys_detect_redis_mode "$redis_namespace")
                    sys_print_execution_details "$redis_namespace" "$redis_mode" "who-is-master"
                    job_who_is_master "$redis_namespace"
                    shift 2
                else
                    echo "Error: --who-is-master 需要提供 namespace。" >&2
                    exit 1
                fi
                ;;
            *)
                echo "未知的選項: '$1'" >&2
                sys_show_help
                exit 1
                ;;
        esac
    done
}

# 系統函式：顯示執行細節
function sys_print_execution_details() {
    local namespace="$1"
    local mode="$2"
    local job="$3"

    echo "執行細節："
    echo "  redis_namespace: $namespace"
    echo "  redis_mode:      $mode"
    echo "  job:             $job"
    echo "-----------------------------"
}

# 系統函式：判斷 namespace 中的 Redis 模式
function sys_detect_redis_mode() {
    local namespace="$1"

    if kubectl -n "$namespace" get sts -l "app.kubernetes.io/component=node" -o jsonpath='{.items[0].metadata.name}' &>/dev/null; then
        echo "sentinel"
        return 0
    fi

    if kubectl -n "$namespace" get sts -l "app.kubernetes.io/component=master" -o jsonpath='{.items[0].metadata.name}' &>/dev/null; then
        echo "standalone"
        return 0
    fi

    echo "none"
    return 1
}

# 任務函式：縮放 StatefulSet
function job_scale() {
    local namespace="$1"
    local number="$2"

    if ! [[ "$number" =~ ^[0-9]+$ ]]; then
        echo "錯誤: 副本數必須是有效的數字。" >&2
        exit 1
    fi

    local mode
    mode=$(sys_detect_redis_mode "$namespace")
    if [[ "$mode" == "none" ]]; then
        echo "找不到任何匹配的 Redis 模式在 namespace '$namespace' 中。" >&2
        exit 1
    fi

    # 在縮放前顯示 Pod 狀態
    echo "縮放前的 Pod 狀態："
    kubectl -n "$namespace" get pods -o wide

    if [[ "$mode" == "standalone" ]]; then
        if (( number < 0 || number > 1 )); then
            echo "錯誤: 對於 'standalone' 模式，副本數必須在 0~1 範圍內。" >&2
            exit 1
        fi
        local standalone_sts
        standalone_sts=$(kubectl -n "$namespace" get sts -l "app.kubernetes.io/component=master" -o jsonpath='{.items[0].metadata.name}')
        if [[ -n "$standalone_sts" ]]; then
            echo "正在縮放 'standalone' 模式的 StatefulSet '$standalone_sts' 至 $number 副本數..."
            kubectl -n "$namespace" scale sts/"$standalone_sts" --replicas="$number"
            kubectl -n "$namespace" rollout status sts/"$standalone_sts"
        fi
    fi

    if [[ "$mode" == "sentinel" ]]; then
        if (( number < 0 || number > 3 )); then
            echo "錯誤: 對於 'sentinel' 模式，副本數必須在 0~3 範圍內。" >&2
            exit 1
        fi
        local sentinel_sts
        sentinel_sts=$(kubectl -n "$namespace" get sts -l "app.kubernetes.io/component=node" -o jsonpath='{.items[0].metadata.name}')
        if [[ -n "$sentinel_sts" ]]; then
            echo "正在縮放 'sentinel' 模式的 StatefulSet '$sentinel_sts' 至 $number 副本數..."
            kubectl -n "$namespace" scale sts/"$sentinel_sts" --replicas="$number"
            echo "等待 StatefulSet 縮放完成..."
            kubectl -n "$namespace" rollout status sts/"$sentinel_sts"
        fi
    fi

    # 等待 Pod 狀態穩定
    echo "確認 Pod 狀態穩定，請稍候..."
    sleep 5  # 可根據需要調整等待時間
    while true; do
        local pod_count
        pod_count=$(kubectl -n "$namespace" get pods -l "app.kubernetes.io/component=node" --no-headers 2>/dev/null | wc -l)
        if [[ "$pod_count" -eq "$number" ]]; then
            break
        fi
        sleep 2  # 再次檢查狀態
    done

    # 縮放後顯示穩定的 Pod 狀態
    echo "縮放後的 Pod 狀態："
    kubectl -n "$namespace" get pods -o wide
}

# 任務函式：重啟 StatefulSet
function job_restart() {
    local namespace="$1"

    local mode
    mode=$(sys_detect_redis_mode "$namespace")
    if [[ "$mode" == "none" ]]; then
        echo "找不到任何匹配的 Redis 模式在 namespace '$namespace' 中。" >&2
        exit 1
    fi

    # 在重啟前顯示 Pod 狀態
    echo "重啟前的 Pod 狀態："
    kubectl -n "$namespace" get pods -o wide

    if [[ "$mode" == "standalone" ]]; then
        local standalone_sts
        standalone_sts=$(kubectl -n "$namespace" get sts -l "app.kubernetes.io/component=master" -o jsonpath='{.items[0].metadata.name}')
        if [[ -n "$standalone_sts" ]]; then
            echo "找到 Redis 模式 standalone，正在重新啟動 StatefulSet '$standalone_sts'..."
            kubectl -n "$namespace" rollout restart sts/"$standalone_sts"
        fi
    fi

    if [[ "$mode" == "sentinel" ]]; then
        local sentinel_sts
        sentinel_sts=$(kubectl -n "$namespace" get sts -l "app.kubernetes.io/component=node" -o jsonpath='{.items[0].metadata.name}')
        if [[ -n "$sentinel_sts" ]]; then
            echo "找到 Redis 模式 sentinel，正在重新啟動 StatefulSet '$sentinel_sts'..."
            kubectl -n "$namespace" rollout restart sts/"$sentinel_sts"
        fi
    fi

    # 等待 Pod 重啟完成
    echo "正在等待 Pod 重啟完成..."
    sleep 5  # 等待 5 秒以確保 Pod 開始重啟
    kubectl -n "$namespace" rollout status sts/"$sentinel_sts" || kubectl -n "$namespace" rollout status sts/"$standalone_sts"

    # 重啟後顯示 Pod 狀態
    echo "重啟後的 Pod 狀態："
    kubectl -n "$namespace" get pods -o wide
}

# 任務函式：執行 Failover
function job_failover() {
    local namespace="$1"

    local mode
    mode=$(sys_detect_redis_mode "$namespace")
    if [[ "$mode" == "none" ]]; then
        echo "找不到任何匹配的 Redis 模式在 namespace '$namespace' 中。" >&2
        exit 1
    fi

    if [[ "$mode" == "standalone" ]]; then
        echo "錯誤: 'standalone' 模式不支援 Failover 操作。" >&2
        exit 1
    fi

    if [[ "$mode" == "sentinel" ]]; then
        local sentinel_pod
        sentinel_pod=$(kubectl -n "$namespace" get pod -l "app.kubernetes.io/component=node" -o jsonpath='{.items[0].metadata.name}')
        if [[ -n "$sentinel_pod" ]]; then
            echo "正在對 Sentinel Pod '$sentinel_pod' 執行 Failover 操作..."
            kubectl -n "$namespace" exec -it pod/"$sentinel_pod" -c sentinel -- redis-cli -p 26379 SENTINEL FAILOVER mymaster
        else
            echo "找不到 Sentinel Pod。" >&2
            exit 1
        fi
    fi
}

# 任務函式：找出目前的 Master 並檢查一致性
function job_who_is_master() {
    local namespace="$1"

    local mode
    mode=$(sys_detect_redis_mode "$namespace")
    if [[ "$mode" == "none" ]]; then
        echo "找不到任何匹配的 Redis 模式在 namespace '$namespace' 中。" >&2
        exit 1
    fi

    if [[ "$mode" == "standalone" ]]; then
        echo "錯誤: 'standalone' 模式不支援查詢 Master 操作。" >&2
        exit 1
    fi

    if [[ "$mode" == "sentinel" ]]; then
        # 在操作前顯示 Pod 狀態
        echo "操作前的 Pod 狀態："
        kubectl -n "$namespace" get pods -o wide

        echo
        echo "查詢 namespace '$namespace' 中的所有 Sentinel Pod..."
        local sentinel_pods
        sentinel_pods=$(kubectl -n "$namespace" get pod -l "app.kubernetes.io/component=node" -o jsonpath='{.items[*].metadata.name}')
        
        if [[ -z "$sentinel_pods" ]]; then
            echo "找不到任何 Sentinel Pod。" >&2
            exit 1
        fi

        echo
        echo "以下是 Sentinel Pod 與其 Master 資訊："
        local master_values=()
        for pod in $sentinel_pods; do
            echo "Pod: $pod"
            local master_info
            master_info=$(kubectl -n "$namespace" exec -it pod/"$pod" -c sentinel -- redis-cli -p 26379 INFO sentinel | grep mymaster || echo "No master information available")
            if [[ -n "$master_info" ]]; then
                echo "  $master_info"
                master_values+=("$master_info")
            else
                echo "  無法取得 Master 資訊"
            fi
        done

        echo
        echo "檢查 Master 資訊是否一致..."
        local first_master="${master_values[0]}"
        for master in "${master_values[@]}"; do
            if [[ "$master" != "$first_master" ]]; then
                echo "發現 Master 資訊不一致，將重新啟動 Redis Sentinel..."
                echo
                job_restart "$namespace"
                return
            fi
        done
        echo "所有 Master 資訊一致，無需進一步操作。"
    fi
}

# 主函式
function main() {
    sys_parse_arguments "$@"
}

# 執行主函式
main "$@"
