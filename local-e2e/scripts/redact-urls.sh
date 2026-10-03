redact_urls() {
  sed -E 's,([[:alpha:]][[:alnum:]+.-]*://)([^/?#[:space:]]*@)?(\[[[:xdigit:]:.%]+\]|[[:alnum:]_.-]+)(:[[:digit:]]+)?[^[:space:]]*,\1\3\4,g'
}
