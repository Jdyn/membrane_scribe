defmodule Membrane.RTC.TranscriberTest do
  use ExUnit.Case

  describe "Transcriber GenServer test" do
    test "transcribe" do
      assert {:ok, transcriber_pid} =
               Membrane.RTC.Engine.Endpoint.Scribe.Transcriber.start_link([])

      GenServer.call(transcriber_pid, {:transcribe, <<0, 0, 0, 0>>})
    end
  end
end
