defmodule Membrane.RTC.ScribeEndpointTest do
  use ExUnit.Case

  alias Membrane.RTC.Engine
  alias Membrane.RTC.Engine.Endpoint.HLS
  alias Membrane.RTC.Engine.Endpoint.HLS.{HLSConfig, MixerConfig}
  alias Membrane.RTC.Engine.Message

  @fixtures_dir "./test/fixtures/"
  @audio_file_path Path.join(@fixtures_dir, "audio.aac")

  setup do
    options = [
      id: "test_rtc"
    ]

    {:ok, pid} = Engine.start_link(options, [])

    Engine.register(pid, self())

    on_exit(fn ->
      Engine.terminate(pid)
    end)

    [rtc_engine: pid]
  end

  describe "Scribe Endpoint test" do

  end
end
