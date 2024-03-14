defmodule Membrane.RTC.Engine.Endpoint.Scribe do
  @moduledoc """
  Documentation for `Scribe`.
  """
  use Membrane.Bin

  require Logger

  alias Membrane.RTC.Engine
  alias Membrane.RTC.Engine.Endpoint.WebRTC.{TrackReceiver}
  alias Membrane.RTC.Engine.Track
  alias Membrane.RawAudio
  alias Membrane.RTC.Engine.Endpoint.Scribe.Filter

  def_options rtc_engine: [
                spec: pid(),
                description: "Pid of the parent Engine"
              ]

  def_input_pad :input,
    availability: :on_request,
    accepted_format: Membrane.RTP

  @impl true
  def handle_init(_ctx, opts) do
    state = %{
      rtc_engine: opts.rtc_engine,
      tracks: %{}
    }

    spec = [
      child(:scribe_filter, Filter)
      |> child(:sink, %Membrane.Debug.Sink{})
    ]

    {[notify_parent: :ready, spec: spec], state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, track_id) = pad, _ctx, state) do
    track = Map.fetch!(state.tracks, track_id)

    spec = [
      bin_input(pad)
      |> child({:track_receiver, track_id}, %TrackReceiver{
        track: track,
        initial_target_variant: :high
      })
      |> child({:depayloader, track.id}, Track.get_depayloader(track))
      |> child({:opus_decoder, track.id}, Membrane.Opus.Decoder)
      # Bumblebee Audio requires 16kHz f32le format
      |> child(
        {:converter, track.id},
        %Membrane.FFmpeg.SWResample.Converter{
          output_stream_format: %RawAudio{
            channels: 1,
            sample_format: :f32le,
            sample_rate: 16_000
          }
        }
      )
      |> child(
        {:parser, track.id},
        %Membrane.RawAudioParser{
          stream_format: %RawAudio{
            channels: 1,
            sample_format: :f32le,
            sample_rate: 16_000
          },
          overwrite_pts?: true
        }
      )
      |> via_in(Pad.ref(:input, track.id))
      |> get_child(:scribe_filter)
    ]

    {[spec: spec], state}
  end

  @impl true
  def handle_parent_notification({:new_tracks, tracks}, ctx, state) do
    {:endpoint, endpoint_id} = ctx.name

    state =
      tracks
      |> Enum.filter(fn track -> track.type == :audio end)
      |> Enum.reduce(state, fn track, state ->
        case Engine.subscribe(state.rtc_engine, endpoint_id, track.id) do
          :ok ->
            put_in(state, [:tracks, track.id], track)

          {:error, :invalid_track_id} ->
            Logger.info("""
            Couldn't subscribe to the track: #{inspect(track.id)}. No such track.
            It had to be removed just after publishing it. Ignoring.
            """)

            state

          {:error, reason} ->
            raise "Couldn't subscribe to the track: #{inspect(track.id)}. Reason: #{inspect(reason)}"
        end
      end)

    {[], state}
  end

  def handle_parent_notification(_notification, _ctx, state) do
    # Logger.warning("Scribe Unhandled parent notification: #{inspect(notification)}")
    {[], state}
  end
end
