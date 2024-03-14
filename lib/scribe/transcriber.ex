defmodule Membrane.RTC.Engine.Endpoint.Scribe.Transcriber do
  use GenServer
  require Logger

  @transcribe_timeout 30_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, whisper} = Bumblebee.load_model({:hf, "openai/whisper-tiny"})
    {:ok, featurizer} = Bumblebee.load_featurizer({:hf, "openai/whisper-tiny"})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, "openai/whisper-tiny"})
    {:ok, generation_config} = Bumblebee.load_generation_config({:hf, "openai/whisper-tiny"})

    serving =
      Bumblebee.Audio.speech_to_text_whisper(whisper, featurizer, tokenizer, generation_config,
        defn_options: [compiler: EXLA]
      )

    dbg(serving)

    {:ok, pid} =
      Nx.Serving.start_link(
        serving: serving,
        name: Membrane.RTC.Engine.Endpoint.Scribe.Transcriber.Serving,
        batch_timeout: 100
      )

    IO.inspect("got pid: #{inspect(pid)}")

    {:ok, %{serving: serving, queue: [], pid: pid}}
  end

  def transcribe(audio) do
    GenServer.call(__MODULE__, {:transcribe, audio}, @transcribe_timeout)
  end

  @impl true
  def handle_call({:transcribe, audio}, from, state) do
    audio = Nx.from_binary(audio, :f32)
    state = %{state | queue: state.queue ++ [{from, audio}]}
    send(self(), :process)

    {:noreply, state}
  end

  @impl true
  def handle_info(:process, state) do
    state.queue
    |> Enum.map(fn {from, input} ->
      Task.start(fn ->
        output = Nx.Serving.batched_run(Membrane.RTC.Engine.Endpoint.Scribe.Transcriber.Serving, input)
        IO.inspect(output)
        GenServer.reply(from, output)
      end)
    end)

    {:noreply, %{state | queue: []}}
  end
end
