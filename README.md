# Player

This folder is your starting point. It is an OTP application that compiles,
connects to the platform node, and declares the `WikiRace.Crawler` behavior,
but has no crawler yet. `start/2` and `status/1` in `lib/player/crawler.ex`
raise an error until you write them.

## What to implement

1. `start/2` in `lib/player/crawler.ex`. It receives the start URL and the target URL.
   It starts your crawler processes under your own supervisor and returns `{:ok, pid}`.
   The harness waits at most 15 seconds for it. Start the search and return. Do not
   crawl inside `start/2`.
2. `status/1` in the same module. It receives the pid returned by `start/2` and returns a
   `WikiRace.Status`. The harness calls it every 250 ms and waits at most 250 ms for the
   answer. It must never block.
3. Call `WikiRace.Harness.report/1` as soon as you find a path. The first valid path to
   arrive gets extra points. If you find a shorter path later, call it again.
4. Add your supervisors to the `children` list in `lib/player/application.ex`. The list
   starts empty.

The contract is in `lib/wiki_race/`: `crawler.ex`, `status.ex` and `harness.ex`. Read
these files, but do not change them. Your crawler must ship them as they are.

## Rules

- The only dependencies allowed are `req` (HTTP) and `floki` (HTML parsing). Both are
  already in `mix.exs`.
- Concurrency, distribution and coordination must use OTP: `GenServer`,
  `DynamicSupervisor`, ETS and Erlang distribution.
- Fetch pages only from the Kiwix server. Never request `wikipedia.org`.
- Only one module may declare `@behaviour WikiRace.Crawler`. The harness looks for that
  module on your node. If it finds none, or more than one, the race does not start.

## Paths

An article URL looks like `http://kiwix1:8080/content/wikipedia_en_all_nopic/Tiger`, with
`_` instead of spaces in the title. The two URLs that `start/2` receives look like this.
Links inside a page are relative. Turn them into full URLs using the URL of the page.

A path is the list of article URLs from the start article to the target, both included.
The harness checks every path you report. Each article must link to the next one, and no
article may appear twice. If a path fails this check, your score for the race is -1.0.

A race lasts 120 seconds. `../SCORING.md` explains the score.

## Testing

`mix test` runs `test/wiki_race/contract_test.exs`. It checks that `start/2` returns a
live pid and that `status/1` returns a `WikiRace.Status`. It fails until you implement
both. It is not graded.

To run a full race on your PC, follow `../RUNNING.md`. The `player1` and `player2`
containers both run this folder. After you change `lib/`, restart them with
`docker compose restart player1 player2`.

## Delivery

You must hand in your implementation of this player.
