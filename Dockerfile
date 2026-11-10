# Same Elixir and Erlang versions as /.tool-versions (Elixir 1.20.2, Erlang 28.5).
# Used only by the local docker-compose setup.
FROM hexpm/elixir:1.20.2-erlang-28.5.0.4-debian-bookworm-20260713-slim

RUN apt-get update -q && \
    apt-get install -y --no-install-recommends git ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=dev

COPY mix.exs mix.lock ./
RUN mix deps.get

COPY . .
RUN mix compile

# docker-compose mounts player/ over /app, so changes in lib/ take effect when
# the container restarts.
CMD ["sh", "-c", "elixir --sname ${NODE_NAME:?} --cookie ${ERL_COOKIE:?} -S mix run --no-halt bin/connect.exs"]
