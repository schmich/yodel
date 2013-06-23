# childprocess
# addressable
# nokogiri

require 'tmpdir'
require 'childprocess'
require 'addressable/uri'
require 'open-uri'
require 'nokogiri'

class AudioDownloader
  def self.download(opts)
    video_url = opts[:url]
    start_sec = opts[:start] || 0
    end_sec = opts[:end]
    artist = opts[:artist]
    title = opts[:title]

    uri = Addressable::URI.parse(video_url)
    uri.query_values = uri.query_values.merge(:hd => 1)
    video_url = uri.to_s

    Dir.mktmpdir do |output_dir|
      wav_file = File.join(output_dir, 'out.wav')

      puts "Downloading raw audio from #{video_url}."
      puts "Target: #{wav_file}."

      vlc_download_audio(video_url, wav_file)

      mp3_file = File.join(output_dir, 'out.mp3')

      puts "Transcoding from raw audio to mp3."
      puts "Target: #{mp3_file}."

      ffmpeg_convert(wav_file, mp3_file, start_sec, end_sec, :artist => artist, :title => title)

      file_name = sanitize_file_name("#{artist} - #{title}.mp3")
      output_file = File.join(Dir.pwd, file_name)

      # TODO: Scrub file name for invalid characters.
      File.rename(mp3_file, output_file)

      puts "mp3 written to #{output_file}."
      puts "Fin."
    end
  end

private
  def self.ffmpeg_convert(input_file, output_file, start_sec, end_sec, metadata = {})
    id3_tags = metadata.map { |k, v|
      ['-metadata', "#{k.id2name}=#{v}"]
    }.flatten

    read, write = IO.pipe

    if end_sec
      duration = ['-t', (end_sec - start_sec + 1).to_s]
    else
      duration = []
    end

    ffmpeg = ChildProcess.build(
      @@ffmpeg,
      '-i', input_file,
      '-vn',
      '-ab', '256k',
      '-ac', '2',
      '-ar', '48000',
      '-acodec', 'mp3',
      '-ss', start_sec.to_s,
      *duration,
      *id3_tags,
      '-id3v2_version', '3',
      '-write_id3v1', '1',
      output_file
    )

    ffmpeg.io.stdout = ffmpeg.io.stderr = write
    ffmpeg.start

    write.close

    ffmpeg.wait

    # TODO: Check process return value
  end

  def self.vlc_download_audio(video_url, output_file)
    output_dir = File.dirname(output_file)
    file = File.basename(output_file)

    vlc = ChildProcess.build(
      @@vlc,
      video_url,
      '-vvv',
      '-I', 'dummy',
      '--dummy-quiet',
      '--verbose=2',
      '--logmode=text',
      "--sout=#transcode{vcodec=none,acodec=s32l}:file{dst='#{file}'}",
      'vlc://quit'
    )

    vlc.cwd = output_dir
    vlc.start
    vlc.wait

    # TODO: Check process return value
  end

  def self.executable_path(exe_name)
    path = ENV['PATH']
    if !path
      return nil
    end

    paths = path.split(';')
    paths.each do |path|
      [File.join(path, exe_name), File.join(path, "#{exe_name}.exe")].each do |file_name|
        if File.file?(file_name)
          return File.expand_path(file_name)
        end
      end
    end

    return nil
  end

  def self.sanitize_file_name(file_name)
    file_name.gsub(/\\\/:\*\?"\<\>\|/, '_')
  end

  @@ffmpeg = executable_path('ffmpeg')
  if !@@ffmpeg
    raise RuntimeError, 'Could not find path to ffmpeg.'
  end

  @@vlc = executable_path('vlc')
  if !@@vlc
    raise RuntimeError, 'Could not find path to vlc.'
  end
end

class VideoInfo
  def self.from_url(video_url)
    doc = Nokogiri.HTML(open(video_url))
    title_elem = doc.css("meta[property='og:title']").first

    if !title_elem
      return nil
    end

    orig_title = title_elem['content']
    if !orig_title
      return nil
    end

    encoding_options = {
      :invalid => :replace,
      :undef => :replace,
      :replace => '',
      :universal_newline => true
    }

    full_title = orig_title.encode(Encoding.find('ASCII'), encoding_options)

    full_title = remove_decoration(full_title)
      .gsub(/(\b|_|-)m\/?v(\b|_|-)/i, '')
      .gsub(/(\b|_)music\s+video(hd)?(\b|_|-)/i, '')
      .strip

    if full_title =~ /^(.*?)(-|_)(.*?)$/
      artist = remove_decoration($1)
      title = remove_decoration($3)
      return [orig_title, artist, title]
    else
      return [orig_title, full_title, nil]
    end
  end

private
  def self.remove_decoration(string)
    return string
      .strip
      .gsub(/^\[.*?\]/, '')
      .gsub(/^\(.*?\)/, '')
      .gsub(/^\{.*?\}/, '')
      .gsub(/\[.*?\]$/, '')
      .gsub(/\(.*?\)$/, '')
      .gsub(/\{.*?\}$/, '')
      .gsub(/\s*-\s*$/, '')
      .strip
  end
end

def get_time_offset(prompt)
  print prompt
  time = gets.strip
  if time.empty?
    return nil
  end

  if time =~ /^:(\d+)$/
    return $2.to_i
  elsif time =~ /^(\d+):(\d+)$/
    min = $1.to_i
    sec = $2.to_i
    return min * 60 + sec
  end
end

print 'YouTube video URL: '
video_url = gets.strip

video_title, default_artist, default_title = VideoInfo.from_url(video_url)

puts "Video title: #{video_title}"

print "Aritst (default '#{default_artist}'): "
artist = gets.strip
artist = artist.empty? ? default_artist : artist

print "Title (default '#{default_title}'): "
title = gets.strip
title = title.empty? ? default_title : title

start_sec = get_time_offset('Song start (mm:ss): ')
end_sec = get_time_offset('Song end (mm:ss): ')

AudioDownloader.download(
  :url => video_url,
  :start => start_sec,
  :end => end_sec,
  :artist => artist,
  :title => title
)
