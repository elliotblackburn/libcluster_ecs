defmodule ClusterEcs.Strategy do
  @moduledoc """
  This clustering strategy works by loading all ecs tasks that belong to the
  given service.

      config :libcluster,
        topologies: [
          example: [
            strategy: #{__MODULE__},
            config: [
              service_name: "my_service",
              polling_interval: 10_000]]]

  ## Configuration Options

  | Key | Required | Description |
  | --- | -------- | ----------- |
  | `:cluster` | yes | Name of the ECS cluster to look in. |
  | `:service_name` | yes | Name of the ECS service to look for. |
  | `:region` | yes | The AWS region you're running in. |
  | `:app_prefix` | no | Will be prepended to the node's private IP address to create the node name. |
  | `:polling_interval` | no | Number of milliseconds to wait between polls to the AWS api. Defaults to 5_000 |
  """

  use GenServer
  use Cluster.Strategy
  import Cluster.Logger
  require Logger

  alias Cluster.Strategy.State

  @default_polling_interval 5_000

  def start_link(opts) do
    Application.ensure_all_started(:tesla)
    Application.ensure_all_started(:ex_aws)
    GenServer.start_link(__MODULE__, opts)
  end

  # libcluster ~> 3.0
  @impl true
  def init([%State{} = state]) do
    state = state |> Map.put(:meta, MapSet.new())

    {:ok, load(state)}
  end

  @impl true
  def handle_info(:timeout, state) do
    handle_info(:load, state)
  end

  def handle_info(:load, %State{} = state) do
    {:noreply, load(state)}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

  defp load(%State{topology: topology, connect: connect, disconnect: disconnect, list_nodes: list_nodes} = state) do
    case get_nodes(state) do
      {:ok, new_nodelist} ->
        removed = MapSet.difference(state.meta, new_nodelist)

        new_nodelist =
          case Cluster.Strategy.disconnect_nodes(topology, disconnect, list_nodes, MapSet.to_list(removed)) do
            :ok ->
              new_nodelist

            {:error, bad_nodes} ->
              # Add back the nodes which should have been removed, but which couldn't be for some reason
              Enum.reduce(bad_nodes, new_nodelist, fn {n, _}, acc ->
                MapSet.put(acc, n)
              end)
          end

        new_nodelist =
          case Cluster.Strategy.connect_nodes(topology, connect, list_nodes, MapSet.to_list(new_nodelist)) do
            :ok ->
              new_nodelist

            {:error, bad_nodes} ->
              # Remove the nodes which should have been added, but couldn't be for some reason
              Enum.reduce(bad_nodes, new_nodelist, fn {n, _}, acc ->
                MapSet.delete(acc, n)
              end)
          end

        Process.send_after(self(), :load, Keyword.get(state.config, :polling_interval, @default_polling_interval))
        %{state | :meta => new_nodelist}

      _ ->
        Process.send_after(self(), :load, Keyword.get(state.config, :polling_interval, @default_polling_interval))
        state
    end
  end

  @spec get_nodes(State.t()) :: {:ok, MapSet.t()} | {:error, any()}
  def get_nodes(%State{topology: topology, config: config}) do
    region = Keyword.fetch!(config, :region)
    cluster = Keyword.fetch!(config, :cluster)
    service_name = Keyword.fetch!(config, :service_name) |> List.wrap()
    app_prefix = Keyword.get(config, :app_prefix, "app")

    with(
      {:config, :cluster, true} <- {:config, :cluster, config_string?(cluster)},
      {:config, :region, true} <- {:config, :region, config_string?(region)},
      {:config, :service_name, true} <- {:config, :service_name, name_configured?(service_name)},
      {:ok, list_service_body} <- list_services(cluster, region),
      {:ok, service_arns} <- extract_service_arns(list_service_body),
      {:ok, task_arns} <- get_tasks_for_services(cluster, region, service_arns, service_name),
      {:ok, desc_task_body} <- describe_tasks(cluster, task_arns, region),
      {:ok, ips} <- extract_ips(desc_task_body)
    ) do
      {:ok, MapSet.new(ips, & ip_to_nodename(&1, app_prefix))}
    else
      {:config, field, _} ->
        message = "ECS strategy is selected, but #{field} is not configured correctly!"
        warn(topology, message)
        {:error, message}

      err ->
        message = "Error #{inspect(err)} while determining nodes in cluster via ECS strategy."
        warn(topology, message)
        {:error, message}
    end
  end

  defp config_string?(str) when is_binary(str) and str != "", do: true

  defp config_string?(_), do: false

  defp name_configured?([_|_] = names) do
    Enum.all?(names, & name_configured?/1)
  end

  defp name_configured?(name), do: config_string?(name)

  @spec get_tasks_for_services(binary(), binary(), list(binary()), list(binary())) :: {:ok, list(binary())} | {:error, any()}
  defp get_tasks_for_services(cluster, region, service_arns, service_names) do
    Enum.reduce(service_names, {:ok, []}, fn service_name, acc ->
      case acc do
        {:ok, acc_tasks} ->
          with(
            {:ok, service_arn} <- find_service_arn(service_arns, service_name),
            {:ok, list_task_body} <- list_tasks(cluster, service_arn, region),
            {:ok, task_arns} <- extract_task_arns(list_task_body)
          ) do
            {:ok, acc_tasks ++ task_arns}
          end

        other ->
          other
      end
    end)
  end

  defp list_services(cluster, region) do
    params = %{
      "cluster" => cluster,
    }

    "ListServices"
    |> query(params)
    |> ExAws.request(region: region)
    |> list_services(cluster, region, [])
  end

  defp list_services({:ok, %{"nextToken" => next_token, "serviceArns" => service_arns}}, cluster, region, accum) when not is_nil(next_token) do
    params = %{
      "cluster" => cluster,
      "nextToken" => next_token,
    }

    "ListServices"
    |> query(params)
    |> ExAws.request(region: region)
    |> list_services(cluster, region, accum ++ service_arns)
  end
  defp list_services({:ok, %{"serviceArns" => service_arns}}, _cluster, _region, accum) do
    {:ok, %{"serviceArns" => accum ++ service_arns}}
  end
  defp list_services({:error, message}, _cluster, _region, _accum) do
    {:error, message}
  end


  defp list_tasks(cluster, service_arn, region) do
    params = %{
      "cluster" => cluster,
      "serviceName" => service_arn,
      "desiredStatus" => "RUNNING",
    }

    "ListTasks"
    |> query( params)
    |> ExAws.request(region: region)
  end

  defp describe_tasks(cluster, task_arns, region) do
    params = %{
      "cluster" => cluster,
      "tasks" => task_arns,
    }

    "DescribeTasks"
    |> query(params)
    |> ExAws.request(region: region)
  end

  @namespace "AmazonEC2ContainerServiceV20141113"
  defp query(action, params) do
    ExAws.Operation.JSON.new(
      :ecs,
      %{
        data: params,
        headers: [
          {"accept-encoding", "identity"},
          {"x-amz-target", "#{@namespace}.#{action}"},
          {"content-type", "application/x-amz-json-1.1"},
        ]
      }
    )
  end

  defp extract_task_arns(%{"taskArns" => arns}), do: {:ok, arns}
  defp extract_task_arns(_), do: {:error, "unknown task arns response"}

  defp extract_service_arns(%{"serviceArns" => arns}), do: {:ok, arns}
  defp extract_service_arns(_), do: {:error, "unknown service arns response"}

  defp find_service_arn(service_arns, service_name) when is_list(service_arns) do
    with {:ok, regex} <- Regex.compile(service_name) do
      service_arns
      |> Enum.find(&(Regex.match?(regex, &1)))
      |> case do
        nil ->
          Logger.error("no service matching #{service_name} found")
          {:error, "no service matching #{service_name} found"}
        arn ->
          {:ok, arn}
      end
    end
  end
  defp find_service_arn(_, _), do: {:error, "no service arns returned"}

  defp extract_ips(%{"tasks" => tasks}) do
    ips =
      tasks
      |> Enum.flat_map(fn(t) -> Map.get(t, "containers", []) end)
      |> Enum.flat_map(fn(c) -> Map.get(c, "networkInterfaces", []) end)
      |> Enum.map(fn(ni) -> Map.get(ni, "privateIpv4Address") end)
      |> Enum.reject(&is_nil/1)
    {:ok, ips}
  end
  defp extract_ips(_), do: {:error, "can't extract ips"}

  defp ip_to_nodename(ip, app_prefix) do
    :"#{app_prefix}@#{ip}"
  end
end
