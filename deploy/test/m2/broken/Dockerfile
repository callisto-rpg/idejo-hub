# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only
#
# M2 exit check only: "0.1.1", Idejo 0.1.0 whose server refuses to start for one forum
# (delta.*), so an upgrade of all four fails on that one alone and must roll back.
ARG BASE
FROM ${BASE}
USER root
RUN mv /app/bin/server /app/bin/server.real \
  && printf '#!/bin/sh\ncase "$PHX_HOST" in delta.*) echo "deliberately failing release for delta" >&2; exit 1 ;; esac\nexec /app/bin/server.real "$@"\n' > /app/bin/server \
  && chmod 755 /app/bin/server
USER nobody
