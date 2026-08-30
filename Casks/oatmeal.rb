# frozen_string_literal: true

cask "oatmeal" do
  version "0.1.0"
  sha256 :no_check

  url "https://github.com/cameronmalloy/oatmeal/releases/download/v#{version}/Oatmeal.dmg"
  name "Oatmeal"
  desc "Private, local-first meeting transcription and notes"
  homepage "https://github.com/cameronmalloy/oatmeal"

  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"
  depends_on formula: "whisper-cpp"
  depends_on formula: "llama.cpp"

  app "Oatmeal.app"

  zap trash: "~/Library/Application Support/Oatmeal"
end
