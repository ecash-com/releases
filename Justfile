# Format every file in the repo.
fmt:
    oxfmt .
    shfmt --write scripts

# Fail if anything is unformatted or lints dirty. Same as CI.
check:
    oxfmt --check .
    shfmt --diff scripts
    shellcheck scripts/*.sh
    actionlint

# Install the pre-commit hooks.
install-hooks:
    prek install
