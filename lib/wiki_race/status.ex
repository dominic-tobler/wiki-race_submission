defmodule WikiRace.Status do
  @moduledoc """
  A snapshot of a crawler's progress, returned by `c:WikiRace.Crawler.status/1`.

  The dashboard shows these fields during the race. Build the snapshot with `new/1`.
  A misspelled key then raises an error instead of leaving a field empty:

      WikiRace.Status.new(
        current_url: url,
        frontier_size: :queue.len(frontier),
        visited_count: map_size(visited),
        state: :running
      )

  Every field has a default. Keep `frontier_size`, `visited_count` and `state` up to
  date, since the dashboard shows them.
  """

  @typedoc "Where the crawler is in its search."
  @type state :: :running | :found | :exhausted

  @typedoc """
  The list of article URLs from the start article to the target, both included.
  `[]` means no path yet.
  """
  @type path :: [String.t()]

  @typedoc """
  The fields of a snapshot:

    * `current_url`: the article the crawler is reading now.
    * `frontier_size`: how many URLs are waiting to be visited.
    * `visited_count`: how many articles the crawler has fetched.
    * `path`: the best path found so far.
    * `state`: `:running`, `:found` or `:exhausted`.
  """
  @type t :: %__MODULE__{
          current_url: String.t() | nil,
          frontier_size: non_neg_integer(),
          visited_count: non_neg_integer(),
          path: path(),
          state: state()
        }

  defstruct current_url: nil,
            frontier_size: 0,
            visited_count: 0,
            path: [],
            state: :running

  @doc """
  Builds a status from a keyword list or a map. Raises on unknown keys.
  """
  @spec new(Enumerable.t()) :: t()
  def new(fields \\ []), do: struct!(__MODULE__, fields)
end
