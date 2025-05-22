#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ==== НАСТРОЙКИ ====
# Лимит трафика (например, "100 GiB" или "1 TiB") и порог в процентах
LIMIT="500 GiB"
WARNING_THRESHOLD_PERCENT=90

# Тип уведомлений (tg/ntfy)
MSG_TYPE="tg"

# Токен Telegram бота и ID пользователя
BOT_TOKEN="your_token"
CHAT_ID="your_id"

# Топик ntfy.sh
NTFY_TOPIC="your_topic"

# Функция для отправки уведомлений
send_message() {
  local MSG_TYPE="$1"
  local MESSAGE="$2"

  case "$MSG_TYPE" in
      "tg")
          curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
               -d chat_id="${CHAT_ID}" \
               -d text="${MESSAGE}" \
               -d parse_mode="HTML"
          echo
          ;;

      "ntfy")
          # Из MESSAGE отделяем заголовок (имя хоста) и тело (само сообщение)
          local TITLE="${MESSAGE%%$'\n'*}"
          local BODY="${MESSAGE#*$'\n'}"

          if [[ "$BODY" == "$MESSAGE" ]]; then
            TITLE=""
          fi

          curl -s -X POST "https://ntfy.sh/${NTFY_TOPIC}" \
               -H "Title: ${TITLE}" \
               -H "Priority: high" \
               -d "$BODY"
          ;;

      *)
          echo "Ошибка: недопустимый тип уведомлений. Поддерживаются: 'tg', 'ntfy'."
          exit 1
          ;;
  esac
}

# Файлы состояний уведомлений
STATE_FILE_WARN="/var/tmp/traffic_warn_sent"
STATE_FILE_HARD="/var/tmp/traffic_hard_sent"

# Значения по умолчанию
DEBUG=0
REPORT=0
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

        # Отправить отчет о трафике
        -report) REPORT=1
                shift ;;

        # Отправить тестовое уведомление
        -test) send_message "${MSG_TYPE}" "Тестовое уведомление."
                exit 0 ;;

        # Установка имени хоста для уведомлений
        -host) if [[ -n "$2" && ! "$2" =~ ^- ]]; then
                HOST="$2"
                shift 2
            else
                echo "Ошибка: опция -host требует указания имени хоста."
                exit 1
            fi ;;

        # Передать тип уведомлений через аргумент
        -msgtype) if [[ -n "$2" && ! "$2" =~ ^- ]]; then
                MSG_TYPE="$2"
                shift 2
            else
                echo "Ошибка: опция -msgtype требует указания типа уведомлений."
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

        # Передать лимит через аргумент
        -limit) if [[ -n "$2" && ! "$2" =~ ^- ]]; then
                LIMIT="$2"
                shift 2
            else
                echo "Ошибка: опция -limit требует указания лимита трафика. Например: '250 GiB или 1 TiB'"
                exit 1
            fi ;;

        # Передать порог предварительного уведомления через аргумент
        -threshold) if [[ -n "$2" && ! "$2" =~ ^- ]]; then
                WARNING_THRESHOLD_PERCENT="$2"
                shift 2
            else
                echo "Ошибка: опция -threshold требует указания порога в процентах. Например: '90'"
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

# Функция для преобразования байт в удобочитаемый формат
format_bytes() {
  local b=$1
  awk -v b="$b" 'BEGIN {
    if      (b >= 2^40) printf "%.2f TiB", b/2^40;
    else if (b >= 2^30) printf "%.2f GiB", b/2^30;
    else if (b >= 2^20) printf "%.2f MiB", b/2^20;
    else if (b >= 2^10) printf "%.2f KiB", b/2^10;
    else                printf "%d bytes", b;
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
if ! vnstat_output=$(vnstat -m); then
  echo "Ошибка: vnstat упал"; exit 1
fi

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

      readable_total_bytes=$(awk -v n="$total_bytes" 'BEGIN {printf "%.0f", n}')
      readable_limit_bytes=$(awk -v n="$limit_bytes" 'BEGIN {printf "%.0f", n}')

      # === REPORT: единичное отправление сводки ===
      if [[ "$REPORT" -eq 1 ]]; then

        MESSAGE="📊 ${HOST^}
Сводка по трафику за текущий месяц
Использовано: ${total_clean} ${unit_raw}"

        # Логгируем
        echo -e "[$(date +'%d-%m-%y %H:%M:%S %Z')] Отправляю сводку трафика за текущий месяц.."

        send_message "${MSG_TYPE}" "$MESSAGE"
        echo
        exit 0
      fi

      [[ "$DEBUG" -eq 1 ]] && {
        echo "[DEBUG] current_month=$current_month"
        echo "[DEBUG] matched line: $line"
        
        echo "[DEBUG] limit: ${limit_value} ${limit_unit} (${readable_limit_bytes} bytes)"
        echo "[DEBUG] actual: ${total_clean} ${unit_raw} (${readable_total_bytes} bytes)"

        threshold_bytes=$(awk -v lb="$limit_bytes" -v pct="$WARNING_THRESHOLD_PERCENT" 'BEGIN { printf "%.0f", lb * pct / 100 }')
        threshold_readable=$(format_bytes "$threshold_bytes")
        echo "[DEBUG] warning_threshold=${WARNING_THRESHOLD_PERCENT}% (${threshold_readable})"
        echo "[DEBUG] used: $percent_used%"

        echo "[DEBUG] warn state: '$(<"$STATE_FILE_WARN")'"
        echo "[DEBUG] hard state: '$(<"$STATE_FILE_HARD")'"
        messages_status
        echo
      }

      # === ПРЕДУПРЕЖДЕНИЕ ===
      if [[ "$percent_used" -ge "$WARNING_THRESHOLD_PERCENT" && "$percent_used" -lt 100 && "$last_warn_month" != "$current_month" ]]; then

        MESSAGE="⚠️ ${HOST^}
Использовано ${percent_used}% трафика за месяц
${total_clean} ${unit_raw} из ${LIMIT}"

        if [[ "$DEBUG" -eq 1 ]]; then
            echo "[DEBUG] Отправляю (как-бы) предупреждения.."
        else
            # Логгируем
            echo -e "[$(date +'%d-%m-%y %H:%M:%S %Z')] Использовано ${readable_total_bytes} байт из ${readable_limit_bytes} (${percent_used}%)"
            echo "Отправляю предварительное оповещение о трафике.."
            # Отправляем уведомление
            send_message "${MSG_TYPE}" "$MESSAGE"
        fi

        echo "$current_month" > "$STATE_FILE_WARN"
        last_warn_month="$current_month"
        echo
      fi

      # === ПРЕВЫШЕНИЕ ===
      if (( readable_total_bytes >= readable_limit_bytes )) && [[ "$last_hard_month" != "$current_month" ]]; then

        MESSAGE="🚨 ${HOST^}
Превышен месячный лимит трафика!
${total_clean} ${unit_raw} (> ${LIMIT})"

        if [[ "$DEBUG" -eq 1 ]]; then
            echo "[DEBUG] Отправляю (как-бы) основное уведомление.."
        else
            # Логгируем
            echo -e "[$(date +'%d-%m-%y %H:%M:%S %Z')] Использовано ${readable_total_bytes} байт из ${readable_limit_bytes}"
            echo "Отправляю уведомление о превышении лимита."
            # Отправляем уведомление
            send_message "${MSG_TYPE}" "$MESSAGE"
        fi

        echo "$current_month" > "$STATE_FILE_HARD"
        last_hard_month="$current_month"
        echo
      fi

      break
    fi
  done
done <<< "$vnstat_output"
