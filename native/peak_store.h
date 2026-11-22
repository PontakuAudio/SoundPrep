#pragma once
#include "reaper_audio_abi.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <limits>
#include <memory>
#include <string>
#include <vector>

namespace ampeaks {
constexpr int base_peak_frames=256,decode_block_frames=262144;
constexpr int decode_block_samples=2*1024*1024;
constexpr int direct_sample_limit=4'000'000;
// Whole bins can be published as soon as a block finishes. Bound the scratch
// by interleaved samples as well as frames for sources with many channels.
constexpr int block_frames(int channels) {
  return std::min(decode_block_frames,decode_block_samples/channels)/base_peak_frames*base_peak_frames;
}
template<typename Sample> struct PeakRange { Sample low,high; };
using PeakPair=PeakRange<float>;
struct PeakStore {
  std::string path,stamp;
  std::shared_ptr<PCM_source> paint_source;
  int frames,channels;
  double sample_rate;
  std::vector<PeakPair> peaks;
  // Single writer. Published bins are immutable, including the final short bin.
  // -1 marks a failed or cancelled decode.
  std::atomic<int> ready_frames{0};
  std::atomic<bool> cancelled{false};
  std::chrono::steady_clock::time_point finished{};
  std::chrono::steady_clock::duration decode_time{};
  bool recorded=false; // main thread only

  PeakStore(const std::string& file,const std::string& file_stamp,const std::shared_ptr<PCM_source>& source,
            int count,int nch,double rate)
    :path(file),stamp(file_stamp),paint_source(source),frames(count),channels(nch),sample_rate(rate),
     peaks(static_cast<size_t>((count+base_peak_frames-1)/base_peak_frames)*nch) {}
};

inline bool read_frames(PCM_source& source,double rate,int channels,int first,int count,double* samples) {
  PCM_source_transfer_t transfer{};
  transfer.time_s=first/rate;
  transfer.samplerate=rate;
  transfer.nch=channels;
  transfer.length=count;
  transfer.samples=samples;
  source.GetSamples(&transfer);
  return transfer.samples_out==count;
}

inline void reduce_peak_block(const double* frame,int count,int channels,PeakPair* bin) {
  for(int offset=0;offset<count;offset+=base_peak_frames,bin+=channels) {
    for(int ch=0;ch<channels;++ch)bin[ch]={static_cast<float>(frame[ch]),static_cast<float>(frame[ch])};
    frame+=channels;
    const int end=std::min(offset+base_peak_frames,count);
    for(int i=offset+1;i<end;++i,frame+=channels) {
      for(int ch=0;ch<channels;++ch) {
        const float value=static_cast<float>(frame[ch]);
        bin[ch].low=std::min(bin[ch].low,value);
        bin[ch].high=std::max(bin[ch].high,value);
      }
    }
  }
}

inline void build_store(PeakStore& store,PCM_source& source) {
  const auto start=std::chrono::steady_clock::now();
  try {
    const int channels=store.channels;
    if(source.IsAvailable() && source.GetNumChannels()==channels && source.GetSampleRate()==store.sample_rate &&
       std::abs(source.GetLength()*store.sample_rate-store.frames)<=0.5) {
      const int block=block_frames(channels);
      std::vector<double> samples(static_cast<size_t>(std::min(store.frames,block))*channels);
      for(int first=0;first<store.frames && !store.cancelled.load();first+=block) {
        const int count=std::min(block,store.frames-first);
        if(!read_frames(source,store.sample_rate,channels,first,count,samples.data()) ||
           store.cancelled.load())break;
        reduce_peak_block(samples.data(),count,channels,&store.peaks[static_cast<size_t>(first/base_peak_frames)*channels]);
        const bool complete=first+count==store.frames;
        if(complete) {
          store.finished=std::chrono::steady_clock::now();
          store.decode_time=store.finished-start;
        }
        store.ready_frames.store(first+count,std::memory_order_release);
        if(complete)return;
      }
    }
  } catch(...) {} // Decoder or allocation failure is handled on the main thread.
  store.ready_frames.store(-1,std::memory_order_release);
}

inline int read_store_columns(const PeakStore& store,int ready,int width,double start,double span,std::vector<double>& values) {
  if(ready<=0)return 0;
  const double origin=start*store.frames,step=span*store.frames/width;
  if(!std::isfinite(origin) || !std::isfinite(step) || step<=0)return 0;
  auto frame_index=[&store](double edge) {
    return static_cast<int>(std::clamp(edge,0.0,static_cast<double>(store.frames)));
  };
  const int first=frame_index(std::floor(origin));
  const int end=frame_index(std::ceil(origin+width*step));
  if(first>=ready || end<=first)return 0;
  const int channels=store.channels;
  const size_t plane=static_cast<size_t>(width)*channels;
  // Include every bin overlapping the pixel. Both resolutions use the
  // GetPeaks layout: interleaved maxima, then minima at the requested width.
  auto columns=[&](int stride,auto range_at) {
    int x=0;
    for(;x<width;++x) {
      const double left=origin+x*step,right=origin+(x+1)*step;
      if(left>=ready)break;
      const int begin=frame_index(std::floor(left))/stride;
      const int stop=(std::min(ready,frame_index(std::ceil(right)))+stride-1)/stride;
      for(int ch=0;ch<channels;++ch) {
        double low=std::numeric_limits<double>::infinity(),high=-low;
        for(int i=begin;i<stop;++i) {
          const auto range=range_at(i,ch);
          low=std::min(low,static_cast<double>(range.low));
          high=std::max(high,static_cast<double>(range.high));
        }
        const size_t index=static_cast<size_t>(x)*channels+ch;
        values[index]=high;
        values[plane+index]=low;
      }
    }
    return x;
  };
  if(step<base_peak_frames && static_cast<std::int64_t>(end-first)*channels<=direct_sample_limit) {
    const int count=std::min(end,ready)-first;
    try {
      std::vector<double> samples(static_cast<size_t>(count)*channels);
      if(read_frames(*store.paint_source,store.sample_rate,channels,first,count,samples.data())) {
        return columns(1,[&](int frame,int ch) {
          const double value=samples[static_cast<size_t>(frame-first)*channels+ch];
          return PeakRange<double>{value,value};
        });
      }
    } catch(...) {} // The published base peaks still cover this span.
  }
  return columns(base_peak_frames,[&](int bin,int ch) {
    return store.peaks[static_cast<size_t>(bin)*channels+ch];
  });
}
} // namespace ampeaks
