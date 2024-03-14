defmodule Membrane.RTC.Engine.Endpoint.Scribe.MixProject do
  use Mix.Project

  @version "0.1.0-dev"

  def project do
    [
      app: :scribe,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # ML deps
      {:bumblebee, git: "https://github.com/elixir-nx/bumblebee.git"},
      {:exla, "~> 0.7.1"},

      # Engine deps
      {:membrane_rtc_engine, "~> 0.21.0"},
      {:membrane_rtc_engine_webrtc, "~> 0.7.0"},
      {:membrane_raw_audio_format, "~> 0.12.0"},
      {:membrane_ffmpeg_swresample_plugin, "~> 0.19.2"},
      {:membrane_audio_mix_plugin, "~> 0.16.0"}
    ]
  end
end
