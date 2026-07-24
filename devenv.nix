{
  pkgs,
  lib,
  config,
  ...
}:

let
  isDarwin = pkgs.stdenv.isDarwin;

  # nix-provided LLVM (clang, llvm-ar, etc.) — replaces the Makefile's
  # Homebrew probing on macOS. Also used for the ironrdp WASM build.
  llvmToolchain = pkgs.symlinkJoin {
    name = "teleport-llvm-toolchain";
    paths = [
      pkgs.llvmPackages.clang
      pkgs.llvmPackages.llvm
    ];
  };

  # Where cluster state (config, data dir, certs, license) lives. Wiped by `tp-reset`.
  stateDir = "${config.env.DEVENV_STATE}/teleport";

  # Shared shell prelude: resolves the build dir for the selected edition.
  prelude = ''
    set -euo pipefail
    TPDEV_EDITION="''${TPDEV_EDITION:-oss}"
    TPDEV_LICENSE="''${TPDEV_LICENSE:-$TPDEV_SRC/e/fixtures/license-eub.pem}"
    if [ "$TPDEV_EDITION" = "ent" ]; then
      BUILD_DIR="$TPDEV_SRC/e/build"
    else
      BUILD_DIR="$TPDEV_SRC/build"
    fi
  '';

  # Build the local Teleport CLI/server binaries if any are missing. The server
  # can exist after a partial build while CLI binaries do not, so check all.
  ensureBuild = ''
    if [ ! -x "$BUILD_DIR/teleport" ] || [ ! -x "$BUILD_DIR/tctl" ] || [ ! -x "$BUILD_DIR/tsh" ] || [ ! -x "$BUILD_DIR/tbot" ]; then
      echo "teleport/tctl/tsh/tbot binaries missing — building (first run takes a while)..."
      tp-build
    fi
  '';

  # macOS toolchain setup, sourced from nix (no Homebrew). Used both in
  # enterShell (for interactive `make`) and inside processes that shell out to
  # `make` (e.g. the web process's ironrdp WASM build) — processes do NOT run
  # enterShell, so anything that runs the Teleport Makefile must source this.
  # No-op on Linux.
  darwinToolchain = lib.optionalString isDarwin ''
    export SDKROOT="''${SDKROOT:-$(xcrun --show-sdk-path)}"
    export CC="''${CC:-${pkgs.stdenv.cc}/bin/cc}"
    export CXX="''${CXX:-${pkgs.stdenv.cc}/bin/c++}"
    export CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER="$CC"
    export RUSTFLAGS="''${RUSTFLAGS:+$RUSTFLAGS }-C link-arg=-isysroot -C link-arg=$SDKROOT"
    # cc-rs uses these for C dependencies inside the ironrdp WASM build. Use
    # unwrapped LLVM tools so nix's Darwin cc-wrapper does not inject host flags.
    export CC_wasm32_unknown_unknown="${pkgs.llvmPackages.clang-unwrapped}/bin/clang"
    export AR_wasm32_unknown_unknown="${pkgs.llvmPackages.llvm}/bin/llvm-ar"
    # Teleport's ensure-llvm-macos target assigns these with `=` and probes brew
    # while parsing the Makefile. Command-line vars via MAKEFLAGS take precedence.
    export MAKEFLAGS="''${MAKEFLAGS:+$MAKEFLAGS }BREW_DIR=/nonexistent LLVM_PREFIX=llvm LLVM_DIR=${llvmToolchain}"
    # Teleport's Makefile assigns CGOFLAG with `=`, so an exported env var won't
    # override it; inject via MAKEFLAGS (spaces escaped for make's arg parser).
    _cgoflag="CGO_ENABLED=1 CC=$CC CXX=$CXX CGO_CFLAGS=--sysroot=$SDKROOT CGO_LDFLAGS=-Wl,-syslibroot,$SDKROOT"
    export MAKEFLAGS="''${MAKEFLAGS:+$MAKEFLAGS }CGOFLAG=''${_cgoflag// /\\ }"
    # Which `make` binary to use. GNU Make 4.4+ triggers a pathological
    # O(n^2) shell-out explosion on older Teleport branches (v18 and below)
    # due to a bare `export` + recursive $(shell) variables in the Makefile.
    # Default to the system make (resolved via xcrun with a clean PATH to
    # avoid nix interference). /usr/bin/make is an xcrun shim that causes
    # infinite recursion when symlinked, so we resolve the real binary.
    # Override before entering the shell: export TPDEV_MAKE=/path/to/make
    export TPDEV_MAKE="''${TPDEV_MAKE:-$(PATH=/usr/bin:/bin /usr/bin/xcrun --find make)}"
    # Put TPDEV_MAKE on PATH so all `make` invocations (interactive, recursive,
    # pnpm scripts) use it. A symlink in a stable directory avoids temp clutter.
    if [ -x "$TPDEV_MAKE" ]; then
      _make_bin_dir="''${DEVENV_STATE:-/tmp}/make-shim"
      mkdir -p "$_make_bin_dir"
      ln -sf "$TPDEV_MAKE" "$_make_bin_dir/make"
      export PATH="$_make_bin_dir:$PATH"
    fi
  '';
in
{
  # ---------------------------------------------------------------------------
  # Environment
  # ---------------------------------------------------------------------------
  env = {
    # Path to the teleport checkout. Override per-machine in devenv.local.nix:
    #   { lib, ... }: { env.TPDEV_SRC = "/path/to/teleport"; }
    TPDEV_SRC = lib.mkDefault "../teleport";

    # Teleport pins an exact Go patch version in go.mod/versions.mk; nixpkgs may
    # lag by a patch release, so let Go fetch the required toolchain into state.
    GOTOOLCHAIN = lib.mkForce "auto";

    # Skip the expensive web UI rebuild during `tp-build`. The teleport binary
    # will still embed whatever webassets exist (or stubs). Set to "0" if you
    # need a full UI build (e.g. working on the web frontend).
    WEBASSETS_SKIP_BUILD = lib.mkDefault "1";

    # TPDEV_MAKE is applied at runtime (see darwinToolchain) so that
    # users can `export TPDEV_MAKE=...` before entering the shell.

    # "oss" or "ent". Enterprise requires the e/ submodule
    # (make init-submodules-e) and a license (see TPDEV_LICENSE).
    # Not set here so that shell exports and .envrc can override it;
    # the default ("oss") is applied at runtime in the prelude.
    # To use enterprise, either:
    #   export TPDEV_EDITION=ent   (in your shell / .envrc)
    #   or set env.TPDEV_EDITION = "ent"; in devenv.local.nix

    # Path to an enterprise license PEM file. Required when TPDEV_EDITION=ent.
    # Defaults at runtime to $TPDEV_SRC/e/fixtures/license-eub.pem if not set.
    # Override via: export TPDEV_LICENSE=/path/to/license.pem

    TPDEV_STATE = stateDir;
    TPDEV_CONFIG = "${stateDir}/teleport.yaml";
    TPDEV_DATA = "${stateDir}/data";
    TPDEV_CERTS = "${stateDir}/certs";

    # Ports — change here if they clash with something on your machine.
    TPDEV_WEB_PORT = "3080";
    TPDEV_AUTH_PORT = "3025";

    # Default local user and proxy used by tp-bootstrap, tp-login, and tsh.
    TPDEV_USER = lib.mkDefault "dev";
    TPDEV_PROXY = lib.mkDefault "localhost:${config.env.TPDEV_WEB_PORT}";

    # Local Machine ID bot. tbot is on by default; opt out with TPDEV_TBOT=0.
    TPDEV_BOT = lib.mkDefault "local-bot";
    TPDEV_BOT_ROLES = lib.mkDefault "";
    TPDEV_TBOT_DIR = "${stateDir}/tbot";
    TPDEV_TBOT_CONFIG = "${stateDir}/tbot/tbot.yaml";
    TPDEV_TBOT_STORAGE = "${stateDir}/tbot/storage";

    # Local app (always-on time service for application access).
    TPDEV_APP_NAME = lib.mkDefault "time-service";
    TPDEV_APP_PORT = lib.mkDefault "18080";
    TPDEV_APP_TUNNEL_PORT = lib.mkDefault "18081";
    TPDEV_APP_ROLE = lib.mkDefault "time-service-access";

    # Local database service (Postgres on a non-standard port).
    TPDEV_DB_NAME = lib.mkDefault "local-postgres";
    TPDEV_DB_PORT = lib.mkDefault "15432";

    # Static join token for attaching extra local agents (nodes, apps, dbs...).
    TPDEV_JOIN_TOKEN = "local-dev-token";

    # Teleport Unstable
    TELEPORT_UNSTABLE_SCOPES = "yes";
  }
  // lib.optionalAttrs isDarwin {
    # --- macOS toolchain, sourced entirely from nix (no Homebrew) ---
    # nix's clang wrapper knows the bundled SDK's sysroot, so CGO and Rust
    # native linking work without Apple's Command Line Tools.
    CC = "${pkgs.stdenv.cc}/bin/cc";
    CXX = "${pkgs.stdenv.cc}/bin/c++";

    # Point Teleport's Makefile LLVM probing at the nix llvm instead of brew.
    # These satisfy `ensure-llvm-macos` (which otherwise runs `brew --prefix`).
    LLVM_DIR = "${llvmToolchain}";
    LLVM_PREFIX = "llvm";
    BREW_DIR = "/nonexistent"; # ensures BREW_DIR != LLVM_DIR so the check passes
  };

  # ---------------------------------------------------------------------------
  # Toolchain — pinned to build.assets/versions.mk + rust-toolchain.toml.
  # Keep these in sync when Teleport bumps its toolchain:
  #   GOLANG_VERSION, NODE_VERSION (versions.mk); channel (rust-toolchain.toml).
  # ---------------------------------------------------------------------------
  languages.go.enable = true;
  # To pin Go to versions.mk (GOLANG_VERSION, currently go1.26.x), set the
  # package once you've confirmed the attribute exists on your channel, e.g.:
  #   languages.go.package = pkgs.go_1_26;

  # Rust comes from nix (not rustup). A concrete channel version is required
  # to install extra targets like wasm32 (the "nixpkgs" channel can't).
  # Pinned to Teleport's rust-toolchain.toml — keep in sync on toolchain bumps.
  # Requires the rust-overlay input in devenv.yaml.
  languages.rust.enable = true;
  languages.rust.channel = "stable";
  languages.rust.version = "1.94.0"; # rust-toolchain.toml
  languages.rust.targets = [ "wasm32-unknown-unknown" ]; # ironrdp WASM build

  languages.javascript = {
    enable = true;
    # To pin Node to versions.mk (NODE_VERSION, currently 24.x), set the
    # package once confirmed on your channel, e.g.: package = pkgs.nodejs_24;
    pnpm.enable = true;
  };

  packages = with pkgs; [
    # build essentials (a C compiler is already provided by the shell itself)
    gnumake
    git
    llvmPackages.bintools # llvm-ar & friends for the Rust <-> Go static-lib link
    libfido2
    pkg-config
    # local-cluster conveniences
    mkcert
    curl
    jq
    darwin.libresolv
    # test-suite tooling — uncomment if you run these suites locally
    kubernetes-helm # helm chart tests (plus helm-unittest plugin)
    bats # shell test suites
  ];

  # ---------------------------------------------------------------------------
  # Services
  # ---------------------------------------------------------------------------

  # Local Postgres for database access testing. Runs on a non-standard port
  # (15432) to avoid collisions with any system-wide PostgreSQL installation.
  services.postgres = {
    enable = true;
    port = 15432;
    listen_addresses = "127.0.0.1";
    initialDatabases = [ { name = "devdb"; } ];
  };

  # ---------------------------------------------------------------------------
  # Scripts
  # ---------------------------------------------------------------------------

  # Build the binaries we need from the sibling checkout.
   scripts.tp-build.exec = ''
     ${prelude}
     if [ "$TPDEV_EDITION" = "ent" ]; then
       if [ ! -f "$TPDEV_SRC/e/Makefile" ]; then
         echo "e/ submodule missing — running: $TPDEV_MAKE -C $TPDEV_SRC init-submodules-e"
         "$TPDEV_MAKE" -C "$TPDEV_SRC" init-submodules-e
       elif [ "''${TPDEV_SKIP_SUBMODULE_UPDATE:-}" != "1" ]; then
         EXPECTED_SHA=$(git -C "$TPDEV_SRC" ls-tree HEAD e | awk '{print $3}')
         CURRENT_SHA=$(git -C "$TPDEV_SRC/e" rev-parse HEAD)
         if [ "$EXPECTED_SHA" != "$CURRENT_SHA" ]; then
           DIRTY=$(git -C "$TPDEV_SRC/e" status --porcelain)
           if [ -n "$DIRTY" ]; then
             echo "WARNING: e/ submodule is at ''${CURRENT_SHA:0:12} (expected ''${EXPECTED_SHA:0:12}) and has uncommitted changes — skipping update"
           else
             echo "e/ submodule is at ''${CURRENT_SHA:0:12}, updating to ''${EXPECTED_SHA:0:12}"
             git -C "$TPDEV_SRC" submodule update e
           fi
         fi
       fi
       "$TPDEV_MAKE" -C "$TPDEV_SRC/e" build/teleport build/tctl build/tsh build/tbot
     else
       "$TPDEV_MAKE" -C "$TPDEV_SRC" build/teleport build/tctl build/tsh build/tbot
     fi
   '';

  # Trusted local TLS certs via mkcert (optional but recommended: no
  # browser warnings and no --insecure). Installs a local CA on first run.
  scripts.tp-certs.exec = ''
    set -euo pipefail
    mkdir -p "$TPDEV_CERTS" "$TPDEV_SRC/web/certs"
    mkcert -install
    mkcert -cert-file "$TPDEV_CERTS/server.crt" \
           -key-file  "$TPDEV_CERTS/server.key" localhost 127.0.0.1
    # The web dev server (pnpm start-teleport[-e]) expects certs here and may
    # try to provision them itself (via brew) if missing:
    cp "$TPDEV_CERTS/server.crt" "$TPDEV_SRC/web/certs/server.crt"
    cp "$TPDEV_CERTS/server.key" "$TPDEV_SRC/web/certs/server.key"
    echo "certs written to $TPDEV_CERTS and $TPDEV_SRC/web/certs"
    echo "restart the teleport process to pick them up"
  '';

  # (Re)generate the cluster config. Idempotent; runs automatically on `devenv up`.
  scripts.tp-config.exec = ''
    ${prelude}
    mkdir -p "$TPDEV_STATE" "$TPDEV_DATA"

    # Enterprise: stage the license into state and reference it from the config.
    LICENSE_LINE=""
    if [ "$TPDEV_EDITION" = "ent" ]; then
      if [ ! -f "$TPDEV_LICENSE" ]; then
        echo "TPDEV_EDITION=ent but no license at $TPDEV_LICENSE" >&2
        exit 1
      fi
      cp "$TPDEV_LICENSE" "$TPDEV_STATE/license.pem"
      chmod 600 "$TPDEV_STATE/license.pem"
      LICENSE_LINE="license_file: $TPDEV_STATE/license.pem"
    fi

    # If mkcert certs exist (tp-certs), serve them instead of self-signed.
    KEYPAIRS_BLOCK=""
    if [ -f "$TPDEV_CERTS/server.crt" ]; then
      KEYPAIRS_BLOCK="https_keypairs:
      - key_file: $TPDEV_CERTS/server.key
        cert_file: $TPDEV_CERTS/server.crt"
    fi

    APP_SERVICE_BLOCK="app_service:
      enabled: \"yes\"
      apps:
      - name: $TPDEV_APP_NAME
        uri: http://127.0.0.1:$TPDEV_APP_PORT
        labels:
          app: $TPDEV_APP_NAME
          env: local"

    DB_SERVICE_BLOCK="db_service:
      enabled: \"yes\"
      databases:
      - name: $TPDEV_DB_NAME
        protocol: postgres
        uri: 127.0.0.1:$TPDEV_DB_PORT
        static_labels:
          env: local"

    cat > "$TPDEV_CONFIG" <<EOF
    version: v3
    teleport:
      nodename: local
      data_dir: $TPDEV_DATA
      log:
        output: stderr
        severity: ''${TPDEV_LOG_LEVEL:-INFO}
        format:
          output: text

    auth_service:
      enabled: "yes"
      listen_addr: 127.0.0.1:$TPDEV_AUTH_PORT
      cluster_name: teleport-local
      proxy_listener_mode: multiplex
      $LICENSE_LINE
      tokens:
        - "node,proxy,app,db,kube:$TPDEV_JOIN_TOKEN"
      authentication:
        type: local
        # otp alongside webauthn so tsh login works without a hardware key
        second_factors: ["webauthn", "otp"]
        webauthn:
          rp_id: "localhost"

    ssh_service:
      enabled: "yes"
      listen_addr: 127.0.0.1:3022
      labels:
        env: local

    proxy_service:
      enabled: "yes"
      web_listen_addr: 127.0.0.1:$TPDEV_WEB_PORT
      public_addr: localhost:$TPDEV_WEB_PORT
      $KEYPAIRS_BLOCK

    $APP_SERVICE_BLOCK

    $DB_SERVICE_BLOCK
    EOF

    echo "wrote $TPDEV_CONFIG (edition: $TPDEV_EDITION)"
  '';

  # First-time user setup. Run after `devenv up` is healthy.
  scripts.tp-bootstrap.exec = ''
    ${prelude}
    ${ensureBuild}
    "$BUILD_DIR/tctl" -c "$TPDEV_CONFIG" users add "$TPDEV_USER" \
      --roles=access,editor,auditor \
      --logins="$USER"
  '';

  # Wipe all cluster state (users, certs, backend) for a fresh start.
  scripts.tp-reset.exec = ''
    set -euo pipefail
    rm -rf "$TPDEV_STATE"
    echo "cluster state wiped — restart with: devenv up"
  '';

  # Convenience wrappers so `tctl`/`tsh` in this shell always talk to the
  # local cluster with the locally built binaries.
  scripts.tctl.exec = ''
    ${prelude}
    ${ensureBuild}
    exec "$BUILD_DIR/tctl" -c "$TPDEV_CONFIG" "$@"
  '';
  scripts.tsh.exec = ''
    ${prelude}
    ${ensureBuild}
    INSECURE=""
    # Only needed while running on the default self-signed cert.
    [ -f "$TPDEV_CERTS/server.crt" ] || INSECURE="--insecure"
    exec "$BUILD_DIR/tsh" --proxy "$TPDEV_PROXY" $INSECURE "$@"
  '';
  scripts.tp-login.exec = ''
    ${prelude}
    ${ensureBuild}
    INSECURE=""
    # Only needed while running on the default self-signed cert.
    [ -f "$TPDEV_CERTS/server.crt" ] || INSECURE="--insecure"
    exec "$BUILD_DIR/tsh" login --proxy "$TPDEV_PROXY" --user "$TPDEV_USER" $INSECURE "$@"
  '';
  scripts.tbot.exec = ''
    ${prelude}
    ${ensureBuild}
    exec "$BUILD_DIR/tbot" "$@"
  '';
  scripts.tp-tbot-init.exec = ''
    ${prelude}
    ${ensureBuild}
    mkdir -p "$TPDEV_TBOT_DIR" "$TPDEV_TBOT_STORAGE"
    [ -f "$TPDEV_CONFIG" ] || tp-config

    # Ensure the app-access role exists.
    ROLE_FILE="$TPDEV_TBOT_DIR/$TPDEV_APP_ROLE.yaml"
    cat > "$ROLE_FILE" <<EOF
    kind: role
    version: v6
    metadata:
      name: $TPDEV_APP_ROLE
    spec:
      allow:
        app_labels:
          app: $TPDEV_APP_NAME
    EOF
    "$BUILD_DIR/tctl" -c "$TPDEV_CONFIG" create --force "$ROLE_FILE"

    # Idempotently ensure the bot resource exists on the auth server.
    # On first run, create the bot and save the join_uri for tbot to use.
    # On subsequent runs, reuse the saved join_uri.
    JOIN_URI_FILE="$TPDEV_TBOT_DIR/join_uri"
    BOT_EXISTS=0
    if "$BUILD_DIR/tctl" -c "$TPDEV_CONFIG" bots ls --format=json 2>/dev/null | jq -e ".[] | select(.metadata.name == \"$TPDEV_BOT\")" >/dev/null 2>&1; then
      BOT_EXISTS=1
    fi

    # A registered bound-keypair bot cannot recover if its private key was lost.
    if [ "$BOT_EXISTS" = "1" ] && [ ! -s "$TPDEV_TBOT_STORAGE/id_bkp" ]; then
      echo "bot '$TPDEV_BOT' has no local bound-keypair state — recreating it"
      "$BUILD_DIR/tctl" -c "$TPDEV_CONFIG" bots rm "$TPDEV_BOT"
      rm -f "$JOIN_URI_FILE"
      BOT_EXISTS=0
    fi

    if [ "$BOT_EXISTS" = "1" ]; then
      echo "bot '$TPDEV_BOT' already exists — updating roles"
      "$BUILD_DIR/tctl" -c "$TPDEV_CONFIG" bots update "$TPDEV_BOT" --add-roles "$TPDEV_APP_ROLE"
    else
      echo "creating bot '$TPDEV_BOT'"
      ROLE_FLAGS="--roles=$TPDEV_APP_ROLE"
      if [ -n "$TPDEV_BOT_ROLES" ]; then
        ROLE_FLAGS="--roles=$TPDEV_APP_ROLE,$TPDEV_BOT_ROLES"
      fi
      BOT_OUT=$("$BUILD_DIR/tctl" -c "$TPDEV_CONFIG" bots add \
        --format=json \
        --logins="$USER" \
        $ROLE_FLAGS \
        "$TPDEV_BOT")
      echo "$BOT_OUT" | jq -r '.join_uri' > "$JOIN_URI_FILE"
      chmod 600 "$JOIN_URI_FILE"
    fi

    if [ ! -f "$JOIN_URI_FILE" ] || [ ! -s "$JOIN_URI_FILE" ]; then
      echo "ERROR: no saved join_uri for bot '$TPDEV_BOT'" >&2
      echo "Run 'tp-reset' and restart to recreate the bot." >&2
      exit 1
    fi
    JOIN_URI=$(cat "$JOIN_URI_FILE")

    # (Re)write tbot config using the join_uri from bot creation.
    cat > "$TPDEV_TBOT_CONFIG" <<EOF
    version: v2
    join_uri: $JOIN_URI
    storage:
      type: directory
      path: $TPDEV_TBOT_STORAGE
    services: []
    EOF

    chmod 600 "$TPDEV_TBOT_CONFIG"
    echo "wrote $TPDEV_TBOT_CONFIG"
  '';

  # ---------------------------------------------------------------------------
  # Processes (process-compose)
  # ---------------------------------------------------------------------------
  process.manager.implementation = "process-compose";

  processes.teleport = {
    exec = ''
      ${prelude}
      ${darwinToolchain}
      if [ "''${TPDEV_AUTO_CERTS:-1}" != "0" ] && { [ ! -f "$TPDEV_CERTS/server.crt" ] || [ ! -f "$TPDEV_CERTS/server.key" ]; }; then
        echo "trusted local TLS certs missing — running tp-certs (set TPDEV_AUTO_CERTS=0 to skip)"
        tp-certs
      fi
      ${ensureBuild}
      tp-config
      exec "$BUILD_DIR/teleport" start --config "$TPDEV_CONFIG"
    '';
    process-compose = {
      readiness_probe = {
        exec.command = "curl -k -fsS https://localhost:3080/webapi/ping";
        initial_delay_seconds = 10;
        period_seconds = 5;
        failure_threshold = 60;
      };
      availability.restart = "on_failure";
    };
  };

  # Web UI dev server (Vite, with hot reload) for frontend development.
  # Opt-out: TPDEV_WEB=0 devenv up
  #
  # You do NOT need this to use the UI — teleport serves the full web UI on
  # https://localhost:3080 whenever the cluster is up. This process only adds
  # live-reload for editing web/ TypeScript/React code.
  #
  # Note: `pnpm start-teleport` runs the ironrdp WASM build, which Vite needs to
  # resolve static imports. Set TPDEV_SKIP_WASM=1 to skip it only after the
  # generated ironrdp pkg already exists.
  processes.web = {
    exec = ''
      ${prelude}
      ${darwinToolchain}
      if [ "''${TPDEV_WEB:-1}" = "0" ]; then
        echo "web dev server disabled (frontend hot-reload) — enable with:"
        echo "  devenv up"
        echo "the UI is already available at https://localhost:$TPDEV_WEB_PORT"
        exit 0
      fi
      cd "$TPDEV_SRC"
      pnpm install
      SKIP="''${TPDEV_SKIP_WASM:-0}"
      if [ "$SKIP" = "1" ] && { [ ! -f web/packages/shared/libs/ironrdp/pkg/ironrdp.js ] || [ ! -f web/packages/shared/libs/ironrdp/pkg/ironrdp_bg.wasm ]; }; then
        echo "TPDEV_SKIP_WASM=1 ignored: ironrdp pkg is missing; building it once for Vite imports"
        SKIP=0
      fi
      if [ "$TPDEV_EDITION" = "ent" ]; then
        IRONRDP_SKIP_BUILD=$SKIP PROXY_TARGET=localhost:$TPDEV_WEB_PORT pnpm start-teleport-e
      else
        IRONRDP_SKIP_BUILD=$SKIP PROXY_TARGET=localhost:$TPDEV_WEB_PORT pnpm start-teleport
      fi
    '';
    process-compose = {
      depends_on.teleport.condition = "process_healthy";
    };
  };

  # Machine ID bot agent. On by default; opt out with TPDEV_TBOT=0.
  # Bound-keypair state must persist so tbot can prove possession of the key
  # registered during its initial join.
  processes.tbot = {
    exec = ''
      ${prelude}
      ${darwinToolchain}
      if [ "''${TPDEV_TBOT:-1}" = "0" ]; then
        echo "tbot disabled — enable with:"
        echo "  TPDEV_TBOT=1 devenv up"
        exit 0
      fi
      tp-tbot-init
      exec tbot start application-tunnel \
        -c "$TPDEV_TBOT_CONFIG" \
        --app "$TPDEV_APP_NAME" \
        --listen "tcp://127.0.0.1:$TPDEV_APP_TUNNEL_PORT"
    '';
    process-compose = {
      depends_on.teleport.condition = "process_healthy";
      availability.restart = "on_failure";
    };
  };

  # Always-on time service app. Returns the current UTC time on every request.
  processes.time-service = {
    exec = ''
      set -euo pipefail
      if ! command -v nc >/dev/null; then
        echo "nc is required for the time service" >&2
        exit 1
      fi

      echo "time-service listening at http://127.0.0.1:$TPDEV_APP_PORT"
      while true; do
        BODY="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' "''${#BODY}" "$BODY" \
          | nc -l 127.0.0.1 "$TPDEV_APP_PORT"
      done
    '';
  };

  # Prints a "what to do next" banner once the cluster is healthy. Runs after
  # teleport is up so the message lands at the bottom of the process-compose
  # view rather than being buried in early startup logs.
  processes.welcome = {
    exec = ''
      ${prelude}
      cat <<BANNER

      ────────────────────────────────────────────────────────────
       Teleport local cluster is up (edition: $TPDEV_EDITION)

         Web UI:   https://localhost:$TPDEV_WEB_PORT/
                   (served by teleport — use this to log in & explore)

       First time? Create your user (run in another shell):

         tp-bootstrap

       That prints a one-time signup link — open it to set a
       password and register a passkey or OTP. Then sign in at the
       Web UI above, or use the CLI:

         tp-login

       Editing the web UI? Frontend hot-reload is running by default.
       To skip it:

         TPDEV_WEB=0 devenv up

       Machine ID tbot runs by default. To disable it:

         TPDEV_TBOT=0 devenv up

       Services:
         App:  time-service at http://127.0.0.1:$TPDEV_APP_PORT (via tbot tunnel on :$TPDEV_APP_TUNNEL_PORT)
         DB:   $TPDEV_DB_NAME (postgres) at 127.0.0.1:$TPDEV_DB_PORT
               connect: tsh db connect $TPDEV_DB_NAME --db-name=devdb --db-user=$USER

       Trusted localhost TLS certs are provisioned automatically on first start.
       Set TPDEV_AUTO_CERTS=0 to skip, or run 'tp-certs' to regenerate them.
      ────────────────────────────────────────────────────────────

      BANNER
      # keep the process alive so the banner stays visible in the TUI
      sleep infinity
    '';
    process-compose = {
      depends_on.teleport.condition = "process_healthy";
    };
  };

  # Wire the macOS toolchain for interactive `make` in the shell (same snippet
  # the build processes source, so behavior is identical either way).
  enterShell = darwinToolchain + ''
    # Avoid making ordinary interactive shells look like process-compose clients.
    unset PC_SOCKET_PATH PC_CONFIG_FILES

    # Default edition if not already set (e.g. via .envrc or devenv.local.nix)
    export TPDEV_EDITION="''${TPDEV_EDITION:-oss}"

    echo "teleport-devenv (edition: $TPDEV_EDITION)"
    echo "  devenv up       start the local cluster (builds on first run)"
    echo "  tp-bootstrap    create the '$TPDEV_USER' user (prints a signup link)"
    echo "  tp-login        log in as $TPDEV_USER against $TPDEV_PROXY"
    echo "  tbot            local tbot binary wrapper"
    echo "  tp-tbot-init    create local bot config and join token"
    echo "  tp-certs        regenerate trusted local TLS certs via mkcert"
    echo "  tsh / tctl      talk to the local cluster"
    echo "  tp-reset        wipe cluster state"
    echo "  TPDEV_WEB=0 devenv up   skip the web UI hot-reload dev server"
    echo "  TPDEV_TBOT=0 devenv up  skip the tbot process"
    echo ""
    echo "  services: time-service (:$TPDEV_APP_PORT), postgres (:$TPDEV_DB_PORT)"
    echo "  TPDEV_SRC=$TPDEV_SRC"
  '';
}
