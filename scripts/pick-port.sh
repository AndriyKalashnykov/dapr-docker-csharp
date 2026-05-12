#!/usr/bin/env bash
# Pick a free TCP port atomically via the kernel's ephemeral allocator.
# Safer than RANDOM + `ss -tln` polling (no TOCTOU window).
exec python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()'
