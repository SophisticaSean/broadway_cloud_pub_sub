defmodule BroadwayCloudPubSub.GoogleApiClient do
  @moduledoc """
  Default Pub/Sub client used by `BroadwayCloudPubSub.Producer` to communicate with Google
  Cloud Pub/Sub service. This client implements the `BroadwayCloudPubSub.PubsubClient` behaviour
  which defines callbacks for receiving and acknowledging messages.
  """

  import GoogleApi.PubSub.V1.Api.Projects
  alias Broadway.{Message, Acknowledger}
  alias GoogleApi.PubSub.V1.Model.{PullRequest, AcknowledgeRequest}
  require Logger

  @behaviour BroadwayCloudPubSub.RestClient
  @behaviour Acknowledger

  @default_max_number_of_messages 10

  @default_scope "https://www.googleapis.com/auth/pubsub"

  defp conn!(%{token: %{module: token, scope: scope}}) do
    {:ok, token} = token.token(scope)

    GoogleApi.PubSub.V1.Connection.new(token)
  end

  @impl true
  def init(opts) do
    with {:ok, subscription} <- validate_subscription(opts),
         {:ok, token_opts} <- validate_token_opts(opts),
         {:ok, pull_request} <- validate_pull_request(opts) do
      storage_ref =
        Broadway.TermStorage.put(%{
          subscription: subscription,
          token: token_opts
        })

      ack_ref = {__MODULE__, storage_ref}

      {:ok,
       %{
         subscription: subscription,
         token: token_opts,
         pull_request: pull_request,
         ack_ref: ack_ref
       }}
    end
  end

  @impl true
  def receive_messages(demand, opts) do
    pull_request = put_max_number_of_messages(opts.pull_request, demand)

    opts
    |> conn!()
    |> pubsub_projects_subscriptions_pull(
      opts.subscription.projects_id,
      opts.subscription.subscriptions_id,
      body: pull_request
    )
    |> wrap_received_messages(opts.ack_ref)
  end

  @impl true
  def ack(ack_ref, successful, _failed) do
    successful
    |> acknowledge_messages(ack_ref)
  end

  defp acknowledge_messages(messages, {_pid, ref}) do
    ack_ids = Enum.map(messages, &extract_ack_id/1)

    opts = Broadway.TermStorage.get!(ref)

    opts
    |> conn!()
    |> pubsub_projects_subscriptions_acknowledge(
      opts.subscription.projects_id,
      opts.subscription.subscriptions_id,
      body: %AcknowledgeRequest{ackIds: ack_ids}
    )
    |> handle_acknowledged_messages()
  end

  defp handle_acknowledged_messages({:ok, _}), do: :ok

  defp handle_acknowledged_messages({:error, reason}) do
    Logger.error("Unable to acknowledge messages with Cloud Pub/Sub. Reason: #{inspect(reason)}")
    :ok
  end

  defp wrap_received_messages({:ok, %{receivedMessages: received_messages}}, ack_ref)
       when is_list(received_messages) do
    Enum.map(received_messages, fn received_message ->
      %Message{
        data: received_message.message,
        acknowledger: {__MODULE__, ack_ref, received_message.ackId}
      }
    end)
  end

  defp wrap_received_messages({:ok, _}, _ack_ref) do
    []
  end

  defp wrap_received_messages({:error, reason}, _) do
    Logger.error("Unable to fetch events from Cloud Pub/Sub. Reason: #{inspect(reason)}")
    []
  end

  defp put_max_number_of_messages(pull_request, demand) do
    max_number_of_messages = min(demand, pull_request.maxMessages)

    %{pull_request | maxMessages: max_number_of_messages}
  end

  defp extract_ack_id(message) do
    {_, _, ack_id} = message.acknowledger
    ack_id
  end

  defp validate(opts, key, default \\ nil) when is_list(opts) do
    validate_option(key, opts[key] || default)
  end

  defp validate_option(:token_module, value) when not is_atom(value),
    do: validation_error(:token_module, "an atom", value)

  defp validate_option(:scope, value) when not is_binary(value) or value == "",
    do: validation_error(:scope, "a non empty string", value)

  defp validate_option(:subscription, value) when not is_binary(value) or value == "",
    do: validation_error(:subscription, "a non empty string", value)

  defp validate_option(:max_number_of_messages, value) when not is_integer(value) or value < 1,
    do: validation_error(:max_number_of_messages, "a positive integer", value)

  defp validate_option(:return_immediately, nil), do: {:ok, nil}

  defp validate_option(:return_immediately, value) when not is_boolean(value),
    do: validation_error(:return_immediately, "a boolean value", value)

  defp validate_option(_, value), do: {:ok, value}

  defp validation_error(option, expected, value) do
    {:error, "expected #{inspect(option)} to be #{expected}, got: #{inspect(value)}"}
  end

  defp validate_pull_request(opts) do
    with {:ok, return_immediately} <- validate(opts, :return_immediately),
         {:ok, max_number_of_messages} <-
           validate(opts, :max_number_of_messages, @default_max_number_of_messages) do
      {:ok,
       %PullRequest{
         maxMessages: max_number_of_messages,
         returnImmediately: return_immediately
       }}
    end
  end

  defp validate_token_opts(opts) do
    with {:ok, token_module} <- validate(opts, :token_module, BroadwayCloudPubSub.GothToken),
         {:ok, scope} <- validate(opts, :scope, @default_scope) do
      {:ok, %{module: token_module, scope: scope}}
    end
  end

  defp validate_subscription(opts) do
    with {:ok, subscription} <- validate(opts, :subscription) do
      subscription |> String.split("/") |> validate_sub_parts(subscription)
    end
  end

  defp validate_sub_parts(
         ["projects", projects_id, "subscriptions", subscriptions_id],
         _subscription
       ) do
    {:ok, %{projects_id: projects_id, subscriptions_id: subscriptions_id}}
  end

  defp validate_sub_parts(_, subscription) do
    validation_error(:subscription, "an valid subscription name", subscription)
  end
end