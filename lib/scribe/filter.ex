defmodule Membrane.RTC.Engine.Endpoint.Scribe.Filter do
  use Membrane.Filter

  require Membrane.Logger

  alias Membrane.Buffer
  alias Membrane.LiveAudioMixer.LiveQueue
  alias Membrane.RawAudio
  alias Membrane.RTC.Engine.Endpoint.Scribe.Transcriber

  @interval Membrane.Time.milliseconds(20)
  @vad_chunk_duration Membrane.Time.milliseconds(500)

  def_options stream_format: [
                spec: %RawAudio{},
                default: %RawAudio{sample_format: :f32le, sample_rate: 16_000, channels: 1},
                description: "Stream format that will be used for output audio"
              ]

  def_input_pad :input,
    availability: :on_request,
    accepted_format: %RawAudio{sample_format: :f32le, sample_rate: 16_000, channels: 1}

  def_output_pad :output,
    accepted_format: Membrane.RemoteStream

  @impl true
  def handle_init(_ctx, options) do
    state =
      options
      |> Map.from_struct()
      |> Map.put(:queue, nil)
      |> Map.put(:scribe, nil)
      |> Map.put(:end_of_stream?, false)
      |> Map.put(:started?, false)
      |> Map.put(:eos_scheduled, false)
      |> Map.put(:speech, <<>>)

    {[], state}
  end

  def handle_setup(_ctx, state) do
    {:ok, scribe} =
      initialize_scribe(%RawAudio{sample_format: :f32le, sample_rate: 16_000, channels: 1})

    queue = LiveQueue.init(%RawAudio{sample_format: :f32le, sample_rate: 16_000, channels: 1})
    # queue = <<>>
    {[notify_parent: :ready], %{state | queue: queue, scribe: scribe}}
  end

  @impl true
  def handle_playing(_context, %{stream_format: %RawAudio{} = stream_format} = state) do
    {[], state}
  end

  @impl true
  def handle_pad_added(_pad, _context, %{end_of_stream?: true}),
    do: raise("Can't add input pad after marking end_of_stream.")

  @impl true
  def handle_pad_added(_pad, _context, %{end_of_stream?: false} = state), do: {[], state}

  @impl true
  def handle_stream_format(:output, _stream_format, _ctx, state) do
    {[stream_format: {:output, %Membrane.RemoteStream{}}], state}
  end

  # @impl true
  # def handle_stream_format(_pad, stream_format, _context, %{stream_format: nil} = state) do
  #   {[stream_format: {:output, stream_format}], state}
  # end

  @impl true
  def handle_stream_format(_pad, stream_format, _context, %{stream_format: stream_format} = state) do
    {[stream_format: {:output, %Membrane.RemoteStream{}}], state}
  end

  @impl true
  def handle_stream_format(pad, stream_format, _context, state) do
    raise(
      RuntimeError,
      "received invalid stream_format on pad #{inspect(pad)}, expected: #{inspect(state.stream_format)}, got: #{inspect(stream_format)}"
    )
  end

  @impl true
  def handle_start_of_stream(
        Pad.ref(:input, pad_id) = pad,
        context,
        %{queue: queue, started?: started?} = state
      ) do
    # offset = context.pads[pad].options.offset
    new_queue = dbg(LiveQueue.add_queue(queue, pad_id, 0))
    # new_queue = <<>>

    {actions, started?} =
      if started?,
        do: {[], started?},
        else: {[start_timer: {:initiator, Membrane.Time.milliseconds(200)}], true}

    {actions, %{state | queue: new_queue, started?: started?}}
  end

  @impl true
  def handle_buffer(
        Pad.ref(:input, pad_id),
        buffer,
        _ctx,
        %{queue: queue, scribe: scribe} = state
      ) do
    # input = state.queue <> buffer.payload
    # if byte_size(input) >
    #      RawAudio.time_to_bytes(@vad_chunk_duration, %RawAudio{
    #        sample_format: :f32le,
    #        sample_rate: 16_000,
    #        channels: 1
    #      }) do
    #   process_data(input, %{state | queue: <<>>})
    # else
    #   {[], %{state | queue: input}}
    # end
    {[], %{state | queue: LiveQueue.add_buffer(queue, pad_id, buffer)}}
  end

  # defp process_data(data, state) do
  #   # Here we filter out the silence at the beginning of each chunk.
  #   # This way we can fit as much speech in a single chunk as possible
  #   # and potentially remove whole silent chunks, which cause
  #   # model hallucinations. If after removing the silence the chunk
  #   # is not empty but too small to process, we store it in the state
  #   # and prepend it to the subsequent chunk.
  #   speech =
  #     if state.speech == <<>> do
  #       filter_silence(data, state)
  #     else
  #       state.speech <> data
  #     end

  #   if byte_size(speech) <
  #        RawAudio.time_to_bytes(Membrane.Time.seconds(5), %RawAudio{
  #          sample_format: :f32le,
  #          sample_rate: 16_000,
  #          channels: 1
  #        }) do
  #     {[], %{state | speech: speech}}
  #   else
  #     result = GenServer.call(state.scribe, {:transcribe, speech})
  #     transcription = Enum.map_join(result.chunks, & &1.text)
  #     IO.inspect(transcription)
  #     buffer = %Membrane.Buffer{payload: transcription}
  #     {[buffer: {:output, buffer}], %{state | speech: <<>>}}
  #   end
  # end

  # defp filter_silence(samples, state) do
  #   samples
  #   |> generate_chunks(
  #     RawAudio.time_to_bytes(@vad_chunk_duration, %RawAudio{
  #       sample_format: :f32le,
  #       sample_rate: 16_000,
  #       channels: 1
  #     })
  #   )
  #   |> Enum.drop_while(&(calc_volume(&1) < 0.03))
  #   |> Enum.join()
  # end

  # defp generate_chunks(samples, chunk_size) when byte_size(samples) >= 2 * chunk_size do
  #   <<chunk::binary-size(chunk_size), rest::binary>> = samples
  #   [chunk | generate_chunks(rest, chunk_size)]
  # end

  # defp generate_chunks(samples, _chunk_size) do
  #   [samples]
  # end

  # # Calculates audio volume based on standard deviation
  # # of the samples
  # defp calc_volume(chunk) do
  #   samples = for <<sample::float-32-little <- chunk>>, do: sample
  #   samples_cnt = Enum.count(samples)
  #   samples_avg = Enum.sum(samples) / samples_cnt
  #   sum_mean_square = samples |> Enum.map(&((&1 - samples_avg) ** 2)) |> Enum.sum()
  #   :math.sqrt(sum_mean_square / samples_cnt)
  # end

  @impl true
  def handle_end_of_stream(
        Pad.ref(:input, pad_id),
        ctx,
        %{eos_scheduled: true, queue: queue} = state
      ) do
    state =
      Map.merge(state, %{
        queue: LiveQueue.remove_queue(queue, pad_id),
        end_of_stream?: all_streams_ended?(ctx)
      })

    {[], state}
  end

  def handle_end_of_stream(Pad.ref(:input, pad_id), _ctx, %{queue: queue} = state),
    do: {[], %{state | queue: LiveQueue.remove_queue(queue, pad_id)}}

  @impl true
  def handle_tick(:initiator, _context, state) do
    {[stop_timer: :initiator, start_timer: {:timer, @interval}], state}
  end

  def handle_tick(:timer, _context, %{end_of_stream?: end_of_stream?} = state) do
    {payload, state} = transcribe(@interval, state)
    # IO.inspect("tick")

    {actions, state} =
      if end_of_stream? and LiveQueue.all_queues_empty?(state.queue) do
        {[end_of_stream: :output, stop_timer: :timer], state}
      else
        {[], state}
      end

    # IO.inspect(payload)

    {[buffer: {:output, %Buffer{payload: payload}}] ++ actions, state}
    # {[], state}
  end

  @impl true
  def handle_parent_notification(
        :schedule_eos,
        context,
        %{started?: started?} = state
      ) do
    state = %{state | eos_scheduled: true}

    if all_streams_ended?(context) and started?,
      do: {[], %{state | end_of_stream?: true}},
      else: {[], state}
  end

  @impl true
  def handle_parent_notification({:start_mixing, _latency}, _context, %{started?: true} = state) do
    Membrane.Logger.warning("Live Audio Mixer has already started mixing.")
    {[], state}
  end

  @impl true
  def handle_parent_notification({:start_mixing, latency}, _context, %{started?: false} = state),
    do: {[start_timer: {:initiator, latency}], %{state | latency: latency, started?: true}}

  defp initialize_scribe(format = %RawAudio{}) do
    Transcriber.start_link(format)
  end

  defp transcribe(duration, %{queue: queue, scribe: scribe} = state) do
    {payloads, new_queue} = LiveQueue.get_audio(queue, duration)

    payloads = Enum.map(payloads, fn {_audio_id, payload} ->
      IO.inspect(payload)
      GenServer.call(scribe, {:transcribe, payload})
    end)

    {payloads, %{state | queue: new_queue}}
  end

  defp all_streams_ended?(%{pads: pads}) do
    pads
    |> Enum.filter(fn {pad_name, _info} -> pad_name != :output end)
    |> Enum.map(fn {_pad, %{end_of_stream?: end_of_stream?}} -> end_of_stream? end)
    |> Enum.all?()
  end
end
