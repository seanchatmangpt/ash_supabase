if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshSupabase.Gen.Resource do
    @example """
    mix ash_supabase.gen.resource MyApp.Blog.Post \\
      --table posts \\
      --attrs title:string:required,body:string,published:boolean
    """

    @shortdoc "Generates an Ash.Resource backed by the Supabase Data API."
    @moduledoc """
    #{@shortdoc}

    Writes a resource that uses `AshSupabase.DataLayer`, points it at a table
    exposed through the Supabase Data API, and gives it the four default
    actions. The generated file is a starting point, not a migration: the table
    must already exist in Postgres, and it must live in a schema listed under
    Project Settings -> API -> Exposed schemas.

    ## Example

    ```sh
    #{@example}
    ```

    produces

    ```elixir
    defmodule MyApp.Blog.Post do
      use Ash.Resource,
        otp_app: :my_app,
        domain: MyApp.Blog,
        data_layer: AshSupabase.DataLayer

      supabase do
        table "posts"
        client MyApp.Supabase
      end

      actions do
        defaults [:read, :destroy, create: :*, update: :*]
      end

      attributes do
        uuid_primary_key :id

        attribute :title, :string do
          allow_nil? false
          public? true
        end

        ...
      end
    end
    ```

    ## Attributes

    `--attrs` takes a comma separated list of `name:type` pairs. Extra
    colon-separated modifiers refine each one:

      * `required` - sets `allow_nil? false`
      * `primary_key` - sets `primary_key? true` and `allow_nil? false`
      * `sensitive` - sets `sensitive? true`, keeping the value out of logs
      * `private` - sets `public? false`, so the attribute is not accepted by
        the default actions and is not exposed by API extensions

    Attributes are public by default, which is what makes `create: :*` and
    `update: :*` useful straight away. Types are Ash type shorthands
    (`:string`, `:integer`, `:utc_datetime_usec`, ...); a capitalized type is
    treated as a module name, so `owner:MyApp.Types.Email` works too.

    ## Options

      * `--table` (`-t`) - the table or view name. Defaults to a naive plural of
        the last module segment, e.g. `MyApp.Blog.Post` -> `posts`.
      * `--attrs` (`-a`) - attributes to generate, as described above.
      * `--client` (`-c`) - the `AshSupabase.Client` module. Defaults to
        `<YourApp>.Supabase`, which is what `mix ash_supabase.install` creates.
      * `--domain` (`-d`) - the domain to add the resource to. Defaults to the
        resource module minus its last segment.
      * `--schema` (`-s`) - the Postgres schema holding the table. Omitted from
        the generated resource unless given, in which case the client's schema
        applies.
      * `--primary-key` - name of the generated UUID primary key. Defaults to
        `id`; pass `--primary-key none` to generate none. An attribute carrying
        the `primary_key` modifier suppresses it automatically.
      * `--timestamps` - also generate `inserted_at`/`updated_at`. Supabase
        tables commonly have `created_at`, so this is off by default.
      * `--yes` (`-y`) - accept all prompts.
    """

    use Igniter.Mix.Task

    @doc false
    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :ash,
        example: @example,
        positional: [:resource],
        composes: ["ash.gen.domain"],
        schema: [
          table: :string,
          attrs: :csv,
          client: :string,
          domain: :string,
          schema: :string,
          primary_key: :string,
          timestamps: :boolean,
          yes: :boolean
        ],
        defaults: [primary_key: "id"],
        aliases: [
          t: :table,
          a: :attrs,
          c: :client,
          d: :domain,
          s: :schema,
          y: :yes
        ]
      }
    end

    @doc false
    @impl Igniter.Mix.Task
    def igniter(igniter) do
      options = igniter.args.options
      resource = Igniter.Project.Module.parse(igniter.args.positional.resource)
      otp_app = Igniter.Project.Application.app_name(igniter)

      domain = domain_module(igniter, resource, options)
      client = client_module(igniter, options)
      table = options[:table] || default_table(resource)
      attributes = parse_attrs(options[:attrs] || [])

      igniter
      |> Igniter.compose_task("ash.gen.domain", [inspect(domain), "--ignore-if-exists"])
      |> Ash.Domain.Igniter.add_resource_reference(domain, resource)
      |> Igniter.Project.Module.find_and_update_or_create_module(
        resource,
        resource_contents(
          otp_app: otp_app,
          domain: domain,
          client: client,
          table: table,
          schema: options[:schema],
          attributes: attributes,
          primary_key: primary_key(options, attributes),
          timestamps?: !!options[:timestamps]
        ),
        fn zipper -> {:ok, zipper} end
      )
      |> Igniter.add_notice("""
      #{inspect(resource)} reads and writes `#{table}` through the Supabase Data API.

      Make sure the table exists and is reachable:

          select * from #{table} limit 1;

      Requests are made with #{inspect(client)}, so Row Level Security policies on
      `#{table}` decide what the anon key can see. Without a policy, a table with RLS
      enabled returns an empty list rather than an error.
      """)
    end

    defp domain_module(igniter, resource, options) do
      case options[:domain] do
        nil ->
          resource |> Module.split() |> Enum.drop(-1) |> Module.concat()

        domain ->
          Igniter.Project.Module.parse(domain)
      end
      |> case do
        # A single-segment resource has no domain to infer, so fall back to the
        # app's own namespace rather than generating `Elixir`.
        Elixir -> Igniter.Project.Module.module_name(igniter, "Domain")
        domain -> domain
      end
    end

    defp client_module(igniter, options) do
      case options[:client] do
        nil -> Igniter.Project.Module.module_name(igniter, "Supabase")
        client -> Igniter.Project.Module.parse(client)
      end
    end

    defp primary_key(options, attributes) do
      cond do
        Enum.any?(attributes, & &1.primary_key?) -> nil
        options[:primary_key] in [nil, "", "none", "false"] -> nil
        true -> String.to_atom(options[:primary_key])
      end
    end

    @typedoc "A parsed `--attrs` entry."
    @type attribute :: %{
            name: atom(),
            type: String.t(),
            allow_nil?: boolean(),
            public?: boolean(),
            sensitive?: boolean(),
            primary_key?: boolean()
          }

    @doc """
    Parses `--attrs` entries into attribute descriptions.

        iex> alias Mix.Tasks.AshSupabase.Gen.Resource
        iex> Resource.parse_attrs(["title:string", "body:string"]) |> Enum.map(& &1.name)
        [:title, :body]
    """
    @spec parse_attrs([String.t()]) :: [attribute()]
    def parse_attrs(attrs) do
      Enum.map(attrs, &parse_attr/1)
    end

    @doc """
    Parses a single `name:type[:modifier...]` attribute specification.

        iex> attr = Mix.Tasks.AshSupabase.Gen.Resource.parse_attr("title:string:required")
        iex> {attr.name, attr.type, attr.allow_nil?, attr.public?}
        {:title, ":string", false, true}

        iex> attr = Mix.Tasks.AshSupabase.Gen.Resource.parse_attr("email:MyApp.Types.Email:sensitive:private")
        iex> {attr.type, attr.sensitive?, attr.public?}
        {"MyApp.Types.Email", true, false}
    """
    @spec parse_attr(String.t()) :: attribute()
    def parse_attr(attr) do
      case String.split(attr, ":", trim: true) do
        [name, type | modifiers] ->
          validate_modifiers!(modifiers, attr)
          primary_key? = "primary_key" in modifiers

          %{
            name: String.to_atom(name),
            type: attribute_type(type),
            allow_nil?: not (primary_key? or "required" in modifiers),
            public?: "private" not in modifiers,
            sensitive?: "sensitive" in modifiers,
            primary_key?: primary_key?
          }

        _ ->
          raise ArgumentError, """
          Invalid attribute #{inspect(attr)}.

          Attributes are given as `name:type`, with optional modifiers, i.e

              --attrs title:string:required,body:string
          """
      end
    end

    defp validate_modifiers!(modifiers, attr) do
      case modifiers -- ~w(required primary_key sensitive private) do
        [] ->
          :ok

        unknown ->
          raise ArgumentError, """
          Unknown attribute modifier#{if length(unknown) == 1, do: "", else: "s"} \
          #{Enum.map_join(unknown, ", ", &inspect/1)} in #{inspect(attr)}.

          Valid modifiers are: required, primary_key, sensitive, private.
          """
      end
    end

    @doc """
    Renders an attribute type. Capitalized types are module names, everything
    else is an Ash type shorthand.

        iex> Mix.Tasks.AshSupabase.Gen.Resource.attribute_type("string")
        ":string"

        iex> Mix.Tasks.AshSupabase.Gen.Resource.attribute_type("MyApp.Types.Email")
        "MyApp.Types.Email"
    """
    @spec attribute_type(String.t()) :: String.t()
    def attribute_type(type) do
      if type =~ ~r/^[A-Z]/ do
        type
      else
        ":" <> type
      end
    end

    @doc """
    The table name inferred from a resource module when `--table` is not given.

        iex> Mix.Tasks.AshSupabase.Gen.Resource.default_table(MyApp.Blog.Post)
        "posts"

        iex> Mix.Tasks.AshSupabase.Gen.Resource.default_table(MyApp.Accounts.Address)
        "addresses"

        iex> Mix.Tasks.AshSupabase.Gen.Resource.default_table(MyApp.Analytics.Status)
        "statuses"
    """
    @spec default_table(module()) :: String.t()
    def default_table(resource) do
      resource
      |> Module.split()
      |> List.last()
      |> Macro.underscore()
      |> pluralize()
    end

    # Deliberately naive: it covers the shapes that show up in resource names,
    # and `--table` is there for everything else.
    defp pluralize(word) do
      cond do
        String.ends_with?(word, ~w(s x z ch sh)) -> word <> "es"
        String.ends_with?(word, "y") -> String.slice(word, 0..-2//1) <> "ies"
        true -> word <> "s"
      end
    end

    @doc false
    @spec resource_contents(keyword()) :: String.t()
    def resource_contents(opts) do
      """
      use Ash.Resource,
        otp_app: #{inspect(opts[:otp_app])},
        domain: #{inspect(opts[:domain])},
        data_layer: AshSupabase.DataLayer

      supabase do
        table #{inspect(opts[:table])}
        client #{inspect(opts[:client])}#{schema_option(opts[:schema])}
      end

      actions do
        defaults [:read, :destroy, create: :*, update: :*]
      end

      attributes do
      #{indent(attributes_body(opts), 2)}
      end
      """
    end

    defp schema_option(nil), do: ""
    defp schema_option(schema), do: "\n  schema #{inspect(schema)}"

    defp attributes_body(opts) do
      [
        primary_key_body(opts[:primary_key]),
        Enum.map(opts[:attributes], &attribute_body/1),
        if(opts[:timestamps?], do: ["timestamps()"], else: [])
      ]
      |> List.flatten()
      |> case do
        [] -> ["# Add attributes with `mix ash_supabase.gen.resource --attrs name:type`"]
        body -> body
      end
      |> Enum.join("\n\n")
    end

    defp primary_key_body(nil), do: []
    defp primary_key_body(name), do: ["uuid_primary_key #{inspect(name)}"]

    defp attribute_body(attribute) do
      options =
        [
          if(attribute.primary_key?, do: "primary_key? true"),
          if(not attribute.allow_nil?, do: "allow_nil? false"),
          "public? #{attribute.public?}",
          if(attribute.sensitive?, do: "sensitive? true")
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      """
      attribute #{inspect(attribute.name)}, #{attribute.type} do
      #{indent(options, 2)}
      end
      """
      |> String.trim_trailing()
    end

    defp indent(text, spaces) do
      pad = String.duplicate(" ", spaces)

      text
      |> String.split("\n")
      |> Enum.map_join("\n", fn
        "" -> ""
        line -> pad <> line
      end)
    end
  end
else
  defmodule Mix.Tasks.AshSupabase.Gen.Resource do
    @shortdoc "Generates a Supabase-backed Ash.Resource | Install `igniter` to use"
    @moduledoc @shortdoc

    use Mix.Task

    @doc false
    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_supabase.gen.resource' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
