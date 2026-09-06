%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: []
      },
      strict: true,
      checks: %{
        disabled: [
          # Guides, moduledocs and worked examples read better unwrapped.
          {Credo.Check.Readability.MaxLineLength, []},
          # The Ash ecosystem calls introspection modules by their full name --
          # `Ash.Resource.Info.attribute/2`, `Spark.Error.DslError` -- because
          # the namespace is what tells you which layer you are in. Aliasing
          # them to bare `Info` would make this code harder to read, not easier.
          {Credo.Check.Design.AliasUsage, []}
        ]
      }
    }
  ]
}
