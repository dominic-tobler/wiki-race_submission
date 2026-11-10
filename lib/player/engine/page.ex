defmodule Player.Engine.Page do
  @moduledoc """
  Fetches article links from the race's Kiwix origin and book only.
  Redirects are disabled so a page cannot send the crawler to the public web.
  """

  def fetch(url) do
    case Req.get(url,
           redirect: false,
           retry: false,
           receive_timeout: 3_000,
           connect_options: [timeout: 3_000]
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> links(body, url)
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  def links(html, base) do
    with {:ok, document} <- Floki.parse_document(html) do
      links =
        document
        |> Floki.attribute("a", "href")
        |> Enum.reject(&(String.trim(&1) == "" or String.starts_with?(&1, "#")))
        |> Enum.map(&resolve(&1, base))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq_by(&key/1)

      {:ok, links}
    end
  end

  def resolve(href, base) do
    uri = URI.merge(base, href)

    if article?(uri, URI.parse(base)) do
      URI.to_string(%{uri | fragment: nil})
    end
  rescue
    ArgumentError -> nil
  end

  def valid_pair?(start, target) do
    start_uri = URI.parse(start)
    target_uri = URI.parse(target)
    article?(start_uri, start_uri) and article?(target_uri, start_uri)
  rescue
    ArgumentError -> false
  end

  # Match the referee's decoded-path comparison while retaining fetchable URLs.
  def key(url) do
    uri = URI.parse(url)
    {uri.scheme, uri.host, uri.port, URI.decode(uri.path || "") |> String.trim_trailing("/")}
  end

  defp article?(uri, base) do
    with ["", "content", book, _article] <- String.split(base.path || "", "/", parts: 4),
         true <- book != "",
         true <- uri.scheme in ["http", "https"] and not is_nil(uri.host),
         true <- {uri.scheme, uri.host, uri.port} == {base.scheme, base.host, base.port},
         true <- is_nil(uri.userinfo) and is_nil(uri.query),
         prefix = "/content/#{book}/",
         true <- String.starts_with?(uri.path || "", prefix),
         title = uri.path |> String.replace_prefix(prefix, "") |> URI.decode() do
      title != "" and
        not String.starts_with?(title, [
          "Special:",
          "File:",
          "Image:",
          "Talk:",
          "Category:",
          "Template:",
          "Help:",
          "User:",
          "Wikipedia:"
        ]) and
        not String.starts_with?(title, ["-", "."]) and
        not String.ends_with?(String.downcase(title), [
          ".css",
          ".js",
          ".png",
          ".jpg",
          ".svg",
          ".woff",
          ".woff2"
        ])
    else
      _ -> false
    end
  end
end
