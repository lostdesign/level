defmodule Level.Mutations do
  @moduledoc """
  Functions for performing GraphQL mutations.
  """

  alias Level.Groups
  alias Level.Posts
  alias Level.Spaces
  alias Level.Spaces.SpaceUser
  alias Level.Users.User

  @typedoc "A context map containing the current user"
  @type authenticated_context :: %{context: %{current_user: User.t()}}

  @typedoc "A list of validation errors"
  @type validation_errors :: [%{attribute: String.t(), message: String.t()}]

  @typedoc "The result of a space mutation"
  @type space_mutation_result ::
          {:ok, %{success: boolean(), space: Spaces.Space.t() | nil, errors: validation_errors()}}
          | {:error, String.t()}

  @typedoc "The result of a group mutation"
  @type group_mutation_result ::
          {:ok, %{success: boolean(), group: Groups.Group.t() | nil, errors: validation_errors()}}
          | {:error, String.t()}

  @typedoc "The payload for a bulk-created group"
  @type bulk_create_group_payload :: %{
          success: boolean(),
          args: %{name: String.t()},
          group: Groups.Group.t() | nil,
          errors: validation_errors
        }

  @typedoc "The result of a bulk create group mutation"
  @type bulk_create_groups_result ::
          {:ok, %{payloads: [bulk_create_group_payload()]}} | {:error, String.t()}

  @typedoc "The result of a post mutation"
  @type post_mutation_result ::
          {:ok, %{success: boolean(), post: Posts.Post.t() | nil, errors: validation_errors()}}
          | {:error, String.t()}

  @typedoc "The result of a setup step mutation"
  @type setup_step_mutation_result ::
          {:ok, %{success: boolean(), state: atom()}} | {:error, String.t()}

  @doc """
  Creates a new space.
  """
  @spec create_space(map(), authenticated_context()) :: space_mutation_result()
  def create_space(args, %{context: %{current_user: user}}) do
    resp =
      case Spaces.create_space(user, args) do
        {:ok, %{space: space}} ->
          %{success: true, space: space, errors: []}

        {:error, :space, changeset, _} ->
          %{success: false, space: nil, errors: format_errors(changeset)}

        _ ->
          %{success: false, space: nil, errors: []}
      end

    {:ok, resp}
  end

  @doc """
  Creates a new group.
  """
  @spec create_group(map(), authenticated_context()) :: group_mutation_result()
  def create_group(args, %{context: %{current_user: user}}) do
    resp =
      with {:ok, %{space_user: space_user}} <- Spaces.get_space(user, args.space_id),
           {:ok, %{group: group}} <- Groups.create_group(space_user, args) do
        %{success: true, group: group, errors: []}
      else
        {:error, :group, changeset, _} ->
          %{success: false, group: nil, errors: format_errors(changeset)}

        _ ->
          %{success: false, group: nil, errors: []}
      end

    {:ok, resp}
  end

  @doc """
  Updates a group.
  """
  @spec update_group(map(), authenticated_context()) :: group_mutation_result()
  def update_group(args, %{context: %{current_user: user}}) do
    with {:ok, %{space_user: space_user}} <- Spaces.get_space(user, args.space_id),
         {:ok, group} <- Groups.get_group(space_user, args.group_id),
         {:ok, updated_group} <- Groups.update_group(group, args) do
      {:ok, %{success: true, group: updated_group, errors: []}}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:ok, %{success: false, group: nil, errors: format_errors(changeset)}}

      err ->
        err
    end
  end

  @doc """
  Create multiple groups.
  """
  @spec bulk_create_groups(map(), authenticated_context()) :: bulk_create_groups_result()
  def bulk_create_groups(args, %{context: %{current_user: user}}) do
    case Spaces.get_space(user, args.space_id) do
      {:ok, %{space_user: space_user}} ->
        payloads =
          Enum.map(args.names, fn name ->
            bulk_create_group(space_user, name)
          end)

        {:ok, %{payloads: payloads}}

      err ->
        err
    end
  end

  @spec bulk_create_group(SpaceUser.t(), String.t()) :: bulk_create_group_payload()
  defp bulk_create_group(space_user, name) do
    args = %{name: name}

    case Groups.create_group(space_user, args) do
      {:ok, %{group: group}} ->
        %{success: true, group: group, errors: [], args: args}

      {:error, :group, changeset, _} ->
        %{success: false, group: nil, errors: format_errors(changeset), args: args}

      _ ->
        %{success: false, group: nil, errors: [], args: args}
    end
  end

  @doc """
  Creates a post.
  """
  @spec create_post(map(), authenticated_context()) :: post_mutation_result()
  def create_post(args, %{context: %{current_user: user}}) do
    with {:ok, %{space_user: space_user}} <- Spaces.get_space(user, args.space_id),
         {:ok, post} <- Posts.create_post(space_user, args) do
      {:ok, %{success: true, post: post, errors: []}}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:ok, %{success: false, post: nil, errors: format_errors(changeset)}}

      err ->
        err
    end
  end

  @doc """
  Marks a space setup step complete.
  """
  @spec complete_setup_step(map(), authenticated_context()) :: setup_step_mutation_result()
  def complete_setup_step(args, %{context: %{current_user: user}}) do
    with {:ok, %{space: space, space_user: space_user}} <- Spaces.get_space(user, args.space_id),
         {:ok, next_state} <- Spaces.complete_setup_step(space_user, space, args) do
      {:ok, %{success: true, state: next_state}}
    else
      err ->
        err
    end
  end

  defp format_errors(%Ecto.Changeset{errors: errors}) do
    Enum.map(errors, fn {attr, {msg, props}} ->
      message =
        Enum.reduce(props, msg, fn {k, v}, acc ->
          String.replace(acc, "%{#{k}}", to_string(v))
        end)

      %{attribute: attr, message: message}
    end)
  end
end