redact_urls() {
  perl -pe 's{(?:https?|wss?)://\S*}{
    $url = $&;
    $url =~ m{\A(?:https?|wss?)://(?:127\.0\.0\.1|localhost|\[::1\])(?::[0-9]+)?(?:[/?#]\S*)?\z}i
      && substr($url, index($url, "://") + 3) !~ m{(?:https?|wss?)://}i
      ? $url : "<redacted-url>"
  }gei'
}
