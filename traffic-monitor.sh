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
               -d parse_mode="HTML" | (command -v jq &>/dev/null && jq . || { cat; echo; })
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
               -d "$BODY" | (command -v jq &>/dev/null && jq . || cat)
          ;;

      *)
          echo "Ошибка: недопустимый тип уведомлений. Поддерживаются: 'tg', 'ntfy'."
          exit 1
          ;;
  esac
}

# Файлы состояний уведомлений и прошлый report
STATE_FILE_WARN="/var/tmp/traffic_warn_sent"
STATE_FILE_HARD="/var/tmp/traffic_hard_sent"
LAST_REPORT="/var/tmp/last_report"

# Значения по умолчанию
DEBUG=0
REPORT=0
MONTHLY="no"
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
        -report)
              REPORT=1
              if [[ "$2" == "monthly" ]]; then
                MONTHLY="yes"
                shift 2
              else
                shift
              fi
              ;;

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
            > "$LAST_REPORT"
            echo "Файлы статусов уведомлений и история отчетов были очищены."
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
    if      (u=="KiB") x=v*2^10;
    else if (u=="MiB") x=v*2^20;
    else if (u=="GiB") x=v*2^30;
    else if (u=="TiB") x=v*2^40;
    else               x=0;
    printf "%.0f", x
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

      if [[ "$DEBUG" -eq 1 && "$REPORT" -ne 1 ]]; then
        echo "[DEBUG] current_month=$current_month"
        echo "[DEBUG] matched line: $line"
        
        echo "[DEBUG] limit: ${limit_value} ${limit_unit} (${limit_bytes} bytes)"
        echo "[DEBUG] actual: ${total_clean} ${unit_raw} (${total_bytes} bytes)"

        threshold_readable=$(format_bytes $(( limit_bytes * WARNING_THRESHOLD_PERCENT / 100 )))
        echo "[DEBUG] warning_threshold=${WARNING_THRESHOLD_PERCENT}% (${threshold_readable})"
        echo "[DEBUG] used: $percent_used%"
        echo "[DEBUG] warn state: '$(<"$STATE_FILE_WARN")'"
        echo "[DEBUG] hard state: '$(<"$STATE_FILE_HARD")'"
        messages_status
      fi

      # === REPORT: единичное отправление сводки ===
      if [[ "$REPORT" -eq 1 ]]; then

        # Читаем предыдущую проверку (если она была)
        if [[ -s "$LAST_REPORT" ]]; then
            read -r last_month last_traffic < "$LAST_REPORT"
        else
            last_month=""
            last_traffic=""
        fi

        # Проверка: есть ли валидные прошлые данные
        if [[ "$last_traffic" =~ ^[0-9]+$ ]]; then
            # Если месяц совпадает или режим monthly - показываем разницу
            if [[ "$last_month" == "$current_month" ]] || [[ "$MONTHLY" == "yes" ]]; then
                traffic_diff=$(( total_bytes - last_traffic ))

                if   (( traffic_diff > 0 )); then diff_message=" (+$(format_bytes "$traffic_diff"))"
                elif (( traffic_diff < 0 )); then diff_message=" (-$(format_bytes "$(( -traffic_diff ))"))"
                else diff_message=" (±0 bytes)"
                fi
            else
                diff_message=""
            fi
        else
            # Первый запуск — не показываем сравнение
            diff_message=""
        fi

        MESSAGE="📊 ${HOST^}
Сводка по трафику за текущий месяц
Использовано: ${total_clean} ${unit_raw}${diff_message}"

        if [[ "$DEBUG" -eq 1 ]]; then
            echo "[DEBUG] current_month: $current_month"
            echo "[DEBUG] is monthly mode: $MONTHLY"
            echo "[DEBUG] LAST_REPORT file content: '$(<"$LAST_REPORT")'"
            # echo "[DEBUG] parsed last_month: '$last_month'"
            # echo "[DEBUG] parsed last_traffic: '$last_traffic'"
            echo "[DEBUG] current total_bytes: '$total_bytes'"
            echo "[DEBUG] calculated traffic_diff: '$traffic_diff'"
            echo "[DEBUG] final diff_message: '$diff_message'"

            echo -e "\n[DEBUG] Отправляю (как-бы) отчет в '${MSG_TYPE}'. Текст сообщения:"
            echo "$MESSAGE"
        else
            # Логгируем
            echo -e "[REPORT] [$(date +'%d-%m-%y %H:%M:%S %Z')] Режим monthly: $MONTHLY. Прошлый замер: '$(<"$LAST_REPORT")'. Текущий: '$total_bytes'"
            echo "Отправляю сводку трафика за текущий месяц в '${MSG_TYPE}'.."

            # Отправляем уведомление
            send_message "${MSG_TYPE}" "$MESSAGE"
            echo
        fi

        # Сохраняем текущие данные (месяц + трафик)
        echo "$current_month $total_bytes" > "$LAST_REPORT"

        exit 0
      fi

      # === ПРЕДУПРЕЖДЕНИЕ ===
      if [[ "$percent_used" -ge "$WARNING_THRESHOLD_PERCENT" && "$percent_used" -lt 100 && "$last_warn_month" != "$current_month" ]]; then

        MESSAGE="⚠️ ${HOST^}
Использовано ${percent_used}% трафика за месяц
${total_clean} ${unit_raw} из ${LIMIT}"

        if [[ "$DEBUG" -eq 1 ]]; then
            echo -e "\n[DEBUG] Отправляю (как-бы) предупреждения в '${MSG_TYPE}'. Текст сообщения:"
            echo "$MESSAGE"
        else
            # Логгируем
            echo -e "[WARN] [$(date +'%d-%m-%y %H:%M:%S %Z')] Использовано ${total_bytes} байт из ${limit_bytes} (${percent_used}%)"
            echo "Отправляю предварительное оповещение о трафике в '${MSG_TYPE}'.."

            # Отправляем уведомление
            send_message "${MSG_TYPE}" "$MESSAGE"
            echo
        fi

        echo "$current_month" > "$STATE_FILE_WARN"
        last_warn_month="$current_month"
      fi

      # === ПРЕВЫШЕНИЕ ===
      if (( total_bytes >= limit_bytes )) && [[ "$last_hard_month" != "$current_month" ]]; then

        MESSAGE="🚨 ${HOST^}
Превышен месячный лимит трафика!
${total_clean} ${unit_raw} (> ${LIMIT})"

        if [[ "$DEBUG" -eq 1 ]]; then
            echo -e "\n[DEBUG] Отправляю (как-бы) основное уведомление в '${MSG_TYPE}'. Текст сообщения:"
            echo "$MESSAGE"
        else
            # Логгируем
            echo -e "[ALERT] [$(date +'%d-%m-%y %H:%M:%S %Z')] Использовано ${total_bytes} байт из ${limit_bytes}"
            echo "Отправляю уведомление о превышении лимита в '${MSG_TYPE}'.."

            # Отправляем уведомление
            send_message "${MSG_TYPE}" "$MESSAGE"
            echo
        fi

        echo "$current_month" > "$STATE_FILE_HARD"
        last_hard_month="$current_month"
      fi

      break
    fi
  done
done <<< "$vnstat_output"
