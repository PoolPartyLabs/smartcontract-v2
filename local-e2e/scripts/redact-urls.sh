redact_urls() {
  sed -E 's,([Hh][Tt][Tt][Pp][Ss]?://)[^/?#[:space:]"'"'"'`)]+@,\1,g; s,([Hh][Tt][Tt][Pp][Ss]?://[^/?#[:space:]"'"'"'`)]+)[/?#][^[:space:]"'"'"'`)]*,\1/...,g'
}
