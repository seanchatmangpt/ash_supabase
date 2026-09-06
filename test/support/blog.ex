defmodule AshSupabase.Test.Blog do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshSupabase.Test.Blog.Post)
    resource(AshSupabase.Test.Blog.Tenanted)
    resource(AshSupabase.Test.Blog.UpsertPost)
  end
end

defmodule AshSupabase.Test.Blog.Post do
  @moduledoc false
  use Ash.Resource,
    domain: AshSupabase.Test.Blog,
    data_layer: AshSupabase.DataLayer,
    validate_domain_inclusion?: false

  supabase do
    table("posts")
    client(AshSupabase.Test.Client)
  end

  attributes do
    uuid_primary_key(:id, writable?: true)
    attribute(:title, :string, public?: true, allow_nil?: false)
    attribute(:body, :string, public?: true)
    attribute(:views, :integer, public?: true, default: 0)
    attribute(:published?, :boolean, public?: true, source: :is_published, default: false)
    attribute(:status, :atom, public?: true, constraints: [one_of: [:draft, :published]])
    attribute(:tags, {:array, :string}, public?: true)
    attribute(:metadata, :map, public?: true)
    create_timestamp(:inserted_at)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

defmodule AshSupabase.Test.Blog.UpsertPost do
  @moduledoc false
  use Ash.Resource,
    domain: AshSupabase.Test.Blog,
    data_layer: AshSupabase.DataLayer,
    validate_domain_inclusion?: false

  supabase do
    table("posts")
    client(AshSupabase.Test.Client)
  end

  attributes do
    uuid_primary_key(:id, writable?: true)
    attribute(:title, :string, public?: true, allow_nil?: false)
    attribute(:body, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy, update: :*])

    create :upsert_post do
      accept([:id, :title, :body])
      upsert?(true)
      upsert_identity(:unique_title)
    end
  end

  identities do
    identity(:unique_title, [:title])
  end
end

defmodule AshSupabase.Test.Blog.Tenanted do
  @moduledoc false
  use Ash.Resource,
    domain: AshSupabase.Test.Blog,
    data_layer: AshSupabase.DataLayer,
    validate_domain_inclusion?: false

  supabase do
    table("tenanted")
    client(AshSupabase.Test.Client)
  end

  multitenancy do
    strategy(:context)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end
