#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ==== НАСТРОЙКИ ====
# Лимит трафика (например, "100 GiB" или "1 TiB") и порог в процентах
LIMIT="500 GiB"
WARNING_THRESHOLD_PERCENT=90

# Токен Telegram бота и ID пользователя
BOT_TOKEN="your_token"
CHAT_ID="your_id"

# Функция для отправки уведомлений
send_message() {
  local MESSAGE="$1"
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
             -d chat_id="${CHAT_ID}" \
             -d text="${MESSAGE}" \
             -d parse_mode="HTML"
}

# Файлы состояний уведомлений
STATE_FILE_WARN="/var/tmp/traffic_warn_sent"
STATE_FILE_HARD="/var/tmp/traffic_hard_sent"

# Значения по умолчанию
DEBUG=0
HOST=$(hostname)
current_month=$(date +'%Y-%m')

# ==== НАЧАЛО СКРИПТА ====
for cmd in vnstat curl awk sed tr; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Ошибка: для работы требуется утилита '$cmd'. Скрипт завершён."
    exit 1
  fi
done

# ==== ОБРАБОТКА АРГУМЕНТОВ ====
while [[ $# -gt 0 ]]; do
    case "$1" in
        # Включение режима отладки
        -debug) DEBUG=1
                shift ;;
        # Установка имени хоста для уведомлений
        -host) if [[ -n "$2" && ! "$2" =~ ^- ]]; then
                HOST="$2"
                shift 2
            else
                echo "Ошибка: опция -host требует указания имени хоста."
                exit 1
            fi ;;
        # "Забыть" что уведомления за месяц уже отправлялись
        -reset)
            > "$STATE_FILE_WARN"
            > "$STATE_FILE_HARD"
            echo "Файлы статусов уведомлений были очищены."
            exit 0 ;;
        # Указать "текущий" месяц
        -month) if [[ -n "$2" && ! "$2" =~ ^- ]]; then
                current_month="$2"
                shift 2
            else
                echo "Ошибка: опция -month требует указания месяца. Например: 2025-05"
                exit 1
            fi ;;
        -*) echo "Неизвестный аргумент: $1"; exit 1 ;;
        *) echo "Неизвестный аргумент: $1"; exit 1 ;;
    esac
done

# Функция перевода в байты
to_bytes() {
  local val=$1 unit=$2
  awk -v v="$val" -v u="$unit" 'BEGIN {
    if      (u=="KiB") print v*2^10;
    else if (u=="MiB") print v*2^20;
    else if (u=="GiB") print v*2^30;
    else if (u=="TiB") print v*2^40;
    else print 0;
  }'
}

# ==== ПРОВЕРКА, БЫЛО ЛИ УВЕДОМЛЕНИЕ ====
last_warn_month=$(cat "$STATE_FILE_WARN" 2>/dev/null || echo "")
last_hard_month=$(cat "$STATE_FILE_HARD" 2>/dev/null || echo "")

messages_status() {
  if [[ "$last_warn_month" == "$current_month" ]]; then
    [[ "$DEBUG" -eq 1 ]] && echo "[DEBUG] Предупреждение уже отправлено."
  else
    [[ "$DEBUG" -eq 1 ]] && echo "[DEBUG] Предупреждение ещё не отправлено."
  fi

  if [[ "$last_hard_month" == "$current_month" ]]; then
    [[ "$DEBUG" -eq 1 ]] && echo "[DEBUG] Основное уведомление уже отправлено."
  else
    [[ "$DEBUG" -eq 1 ]] && echo "[DEBUG] Основное уведомление ещё не отправлено."
  fi

  if [[ "$last_warn_month" == "$current_month" && "$last_hard_month" == "$current_month" ]]; then
    [[ "$DEBUG" -eq 1 ]] && echo "[DEBUG] Все уведомления уже отправлены."
  fi
}

# ==== ЛИМИТ ====
limit_value=$(echo "$LIMIT" | awk '{print $1}' | tr -d ' ' | sed 's/,/./g')
limit_unit=$(echo "$LIMIT" | awk '{print $2}')
limit_bytes=$(to_bytes "$limit_value" "$limit_unit")

# ==== ОБРАБОТКА VNSTAT ====
vnstat_output=$(vnstat -m) || { echo "Ошибка: vnstat упал"; exit 1; }

# Проверяем, есть ли статистика за текущий месяц
if ! grep -qw "$current_month" <<< "$vnstat_output"; then
  echo "Нет данных vnstat за месяц '$current_month'. Скрипт завершён."
  exit 1
fi

while IFS= read -r line; do
  # Разбиваем строку на массив
  read -ra words <<< "$line"

  for ((i=0; i<${#words[@]}; i++)); do
    if [[ "${words[i]}" == "$current_month" ]]; then
      total_raw="${words[i+7]}"
      unit_raw="${words[i+8]}"
      total_clean=$(echo "$total_raw" | tr -d ' ' | sed 's/,/./g')
      total_bytes=$(to_bytes "$total_clean" "$unit_raw")

      # Считаем процент использования
      percent_used=$(awk -v used="$total_bytes" -v max="$limit_bytes" 'BEGIN {printf "%d", (used / max) * 100}')

      readable_total_bytes=$(printf "%.0f" "$total_bytes")
      readable_limit_bytes=$(printf "%.0f" "$limit_bytes")

      [[ "$DEBUG" -eq 1 ]] && {
        echo "[DEBUG] current_month=$current_month"
        echo "[DEBUG] matched line: $line"
        
        echo "[DEBUG] limit: ${limit_value} ${limit_unit} (${readable_limit_bytes} bytes)"
        echo "[DEBUG] actual: ${total_clean} ${unit_raw} (${readable_total_bytes} bytes)"

        echo "[DEBUG] warning_threshold=$WARNING_THRESHOLD_PERCENT%"
        echo "[DEBUG] used: $percent_used%"
        messages_status
        echo
      }

      # === ПРЕДУПРЕЖДЕНИЕ ===
      if [[ "$percent_used" -ge "$WARNING_THRESHOLD_PERCENT" && "$percent_used" -lt 100 && "$last_warn_month" != "$current_month" ]]; then

        MESSAGE="⚠️ ${HOST^}
Использовано ${percent_used}% трафика за месяц
${total_clean} ${unit_raw} из ${LIMIT}"

        [[ "$DEBUG" -eq 1 ]] && echo "[DEBUG] Отправляю предупреждения.."

        # Логгируем
        echo -e "[$(date +'%d-%m-%y %H:%M:%S %Z')] Использовано ${readable_total_bytes} байт из ${readable_limit_bytes} (${percent_used}%)"
        echo "Отправляю предварительное оповещение о трафике.."

        # Отправляем уведомление
        send_message "$MESSAGE"

        echo "$current_month" > "$STATE_FILE_WARN"
        last_warn_month="$current_month"
        echo -e "\n\n"
      fi

      # === ПРЕВЫШЕНИЕ ===
      if (( readable_total_bytes >= readable_limit_bytes )) && [[ "$last_hard_month" != "$current_month" ]]; then

        MESSAGE="🚨 ${HOST^}
Превышен месячный лимит трафика!
${total_clean} ${unit_raw} (> ${LIMIT})"

        [[ "$DEBUG" -eq 1 ]] && echo "[DEBUG] Отправляю основное уведомление.."

        # Логгируем
        echo -e "[$(date +'%d-%m-%y %H:%M:%S %Z')] Использовано ${readable_total_bytes} байт из ${readable_limit_bytes}"
        echo "Отправляю уведомление о превышении лимита."

        # Отправляем уведомление
        send_message "$MESSAGE"

        echo "$current_month" > "$STATE_FILE_HARD"
        last_hard_month="$current_month"
        echo -e "\n\n"
      fi

      break
    fi
  done
done <<< "$vnstat_output"
