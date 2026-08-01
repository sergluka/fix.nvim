# syntax=docker/dockerfile:1
# fix.nvim integration test image — multi-stage.
# All pinned values are hardcoded string literals; no ARG, no --build-arg.

FROM debian:bookworm-slim AS builder

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        gcc \
        git \
        libc6-dev \
        make \
        nodejs \
        npm \
    && npm install -g tree-sitter-cli \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# (a) Compile tree-sitter-fix into fix.so.
RUN set -eux; \
    git clone https://github.com/sergluka/tree-sitter-fix /src/tree-sitter-fix; \
    git -C /src/tree-sitter-fix checkout bd20b510945dde4ecd2213e52b63f9c2a18a3d04; \
    cd /src/tree-sitter-fix; \
    if [ -f grammar.js ] && [ ! -f src/parser.c ]; then tree-sitter generate; fi; \
    mkdir -p /out; \
    cc -O2 -shared -fPIC -Isrc src/parser.c -o /out/fix.so

# (b) Bake Lua dependencies — git clone + checkout + prune .git.
# SHAs are inlined below; updating any pin is a one-line edit.
RUN set -eux; \
    mkdir -p /deps; \
    for entry in \
        "nvim-treesitter https://github.com/nvim-treesitter/nvim-treesitter cf12346a3414fa1b06af75c79faebe7f76df080a" \
        "xml2lua        https://github.com/manoelcampos/xml2lua            b0d2b0b156b4e66078da2dc4b31d978daa69b3ef" \
        "mega.cmdparse  https://github.com/ColinKennedy/mega.cmdparse      47ea5b1b23059fbb79a8e262002f32e7cd8aed90" \
        "mega.logging   https://github.com/ColinKennedy/mega.logging       194ad8c300186e73c3eb1ebeb3ede42eb219be3b" \
        "snacks.nvim    https://github.com/folke/snacks.nvim               0770753c88228f7f15449c6a5b242e3f7cd0d71c" \
        "neo-tree.nvim  https://github.com/nvim-neo-tree/neo-tree.nvim     b01ee1769144c4491ea44bc329cb84040e9793be" \
        "nui.nvim       https://github.com/MunifTanjim/nui.nvim            de740991c12411b663994b2860f1a4fd0937c130" \
        "plenary.nvim   https://github.com/nvim-lua/plenary.nvim           74b06c6c75e4eeb3108ec01852001636d85a932b" \
        "mini.nvim      https://github.com/nvim-mini/mini.nvim             a405061478d8027b4e21214d897ce1eb33115792" \
    ; do \
        set -- $entry; name=$1; url=$2; sha=$3; \
        git clone --no-checkout "$url" "/deps/$name"; \
        git -C "/deps/$name" checkout "$sha"; \
        rm -rf "/deps/$name/.git"; \
    done


FROM debian:bookworm-slim AS runtime

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Neovim release. Bump NEOVIM_VERSION on this one line to switch versions.
RUN set -eux; \
    NEOVIM_VERSION=v0.12.0; \
    curl -fsSL -o /tmp/nvim.tar.gz \
        "https://github.com/neovim/neovim/releases/download/${NEOVIM_VERSION}/nvim-linux-x86_64.tar.gz"; \
    mkdir -p /opt/nvim; \
    tar -xzf /tmp/nvim.tar.gz -C /opt/nvim --strip-components=1; \
    rm /tmp/nvim.tar.gz; \
    ln -s /opt/nvim/bin/nvim /usr/local/bin/nvim

# Pre-built tree-sitter parser; layout matches nvim-treesitter's parser/*.so.
COPY --from=builder /out/fix.so /opt/fix-parser/parser/fix.so

# Baked Lua dependencies.
COPY --from=builder /deps /opt/deps

WORKDIR /plugin

ENV XDG_DATA_HOME=/tmp/xdg-data \
    XDG_CONFIG_HOME=/tmp/xdg-config \
    XDG_STATE_HOME=/tmp/xdg-state \
    XDG_CACHE_HOME=/tmp/xdg-cache \
    TERM=xterm-256color \
    COLORTERM=truecolor

ENTRYPOINT ["nvim"]
CMD ["--headless", "-u", "tests/integration/minimal_init.lua", "-c", "lua require('tests.integration.run')(os.getenv('FIX_NVIM_TEST_FILTER'))"]
