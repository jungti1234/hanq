# Sourced from repository-root test runners. Only the terminal reads sources and
# exports artifacts; launched fixtures use an isolated, non-protected workspace.
hanq_test_stage() {
    mktemp -d "/private/tmp/hanq-$1.XXXXXX"
}

hanq_test_run() (
    cd "$stage"
    "$@"
)
