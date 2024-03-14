defmodule Membrane.RTC.Engine.Endpoint.Scribe.Filter do
  use Membrane.Filter

  require Membrane.Logger

  alias Membrane.Buffer
  alias Membrane.LiveAudioMixer.LiveQueue
  alias Membrane.RawAudio
  alias Membrane.RTC.Engine.Endpoint.Scribe.Transcriber

  @interval Membrane.Time.milliseconds(20)

  def_options stream_format: [
                spec: %RawAudio{},
                default: %RawAudio{sample_format: :f32le, sample_rate: 16_000, channels: 1},
                description: "Stream format that will be used for output audio"
              ]

  def_input_pad :input,
    availability: :on_request,
    accepted_format: %RawAudio{sample_format: :f32le, sample_rate: 16_000, channels: 1}

  def_output_pad :output, accepted_format: Membrane.RemoteStream

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

    {:ok, scribe} = initialize_scribe(options.stream_format)
    queue = LiveQueue.init(options.stream_format)

    {[notify_parent: :ready], %{state | queue: queue, scribe: scribe}}
  end

  @impl true
  def handle_playing(_context, %{stream_format: %RawAudio{} = stream_format} = state) do
    {[stream_format: {:output, stream_format}], state}
  end

  @impl true
  def handle_pad_added(_pad, _context, %{end_of_stream?: true}),
    do: raise("Can't add input pad after marking end_of_stream.")

  @impl true
  def handle_pad_added(_pad, _context, %{end_of_stream?: false} = state), do: {[], state}

  @impl true
  def handle_start_of_stream(
        Pad.ref(:input, pad_id) = pad,
        context,
        %{queue: queue, started?: started?} = state
      ) do
    offset = context.pads[pad].options.offset
    new_queue = LiveQueue.add_queue(queue, pad_id, offset)

    {actions, started?} =
      if started?,
        do: {[], started?},
        else: {[start_timer: :initiator], true}

    {actions, %{state | queue: new_queue, started?: started?}}
  end

  @impl true
  def handle_buffer(Pad.ref(:input, pad_id), buffer, _ctx, %{queue: queue} = state) do
    {[], %{state | queue: LiveQueue.add_buffer(queue, pad_id, buffer)}}
  end

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

    {actions, state} =
      if end_of_stream? and LiveQueue.all_queues_empty?(state.queue) do
        {[end_of_stream: :output, stop_timer: :timer], state}
      else
        {[], state}
      end

    {[buffer: {:output, %Buffer{payload: payload}}] ++ actions, state}
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

    payloads =
      if payloads == [],
        do: [RawAudio.silence(state.stream_format, duration)],
        else: Enum.map(payloads, fn {_audio_id, payload} -> payload end)

    payload = scribe.transcribe(payloads, state)
    {payload, %{state | queue: new_queue}}
  end

  defp all_streams_ended?(%{pads: pads}) do
    pads
    |> Enum.filter(fn {pad_name, _info} -> pad_name != :output end)
    |> Enum.map(fn {_pad, %{end_of_stream?: end_of_stream?}} -> end_of_stream? end)
    |> Enum.all?()
  end
end
