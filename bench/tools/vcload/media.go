package main

import (
	"bytes"
	"errors"
	"fmt"
	"math/rand/v2"
	"os"
	"path/filepath"
)

// clip is the media every user sends, in a loop: H.264 access units at
// 30 fps and Opus packets of 20 ms.
type clip struct {
	video [][]byte
	key   []bool
	audio [][]byte
	gop   int // frames per GOP (keyframe interval)
}

const (
	frameUS = 1_000_000 / 30
	audioUS = 20_000
)

// loadClip reads dir/video.h264 (Annex B, an AUD before each access unit)
// and dir/audio.opus (Ogg Opus). Without them it makes a synthetic clip of
// random bytes of the same sizes, which is enough for the smoke check.
func loadClip(dir string) (*clip, error) {
	vb, verr := os.ReadFile(filepath.Join(dir, "video.h264"))
	ab, aerr := os.ReadFile(filepath.Join(dir, "audio.opus"))
	if verr != nil || aerr != nil {
		return syntheticClip(), nil
	}
	c := &clip{}
	if err := c.parseH264(vb); err != nil {
		return nil, err
	}
	if err := c.parseOgg(ab); err != nil {
		return nil, err
	}
	for i := 1; i < len(c.key); i++ {
		if c.key[i] {
			c.gop = i
			break
		}
	}
	if c.gop == 0 {
		c.gop = len(c.video)
	}
	return c, nil
}

func syntheticClip() *clip {
	c := &clip{gop: 60}
	for i := 0; i < 300; i++ {
		n := 14_000
		if i%60 == 0 {
			n = 90_000
		}
		c.video = append(c.video, randBytes(n))
		c.key = append(c.key, i%60 == 0)
	}
	for i := 0; i < 500; i++ {
		c.audio = append(c.audio, randBytes(160))
	}
	return c
}

func randBytes(n int) []byte {
	b := make([]byte, n)
	for i := range b {
		b[i] = byte(rand.Uint32())
	}
	return b
}

// parseH264 splits an Annex B stream into access units at each AUD (NAL 9);
// an access unit with an IDR slice (NAL 5) is a keyframe.
func (c *clip) parseH264(b []byte) error {
	var starts []int // offsets of start codes
	for i := 0; i+3 < len(b); i++ {
		if b[i] == 0 && b[i+1] == 0 && b[i+2] == 1 {
			s := i
			if i > 0 && b[i-1] == 0 {
				s = i - 1
			}
			starts = append(starts, s)
			i += 2
		}
	}
	if len(starts) == 0 {
		return errors.New("video.h264: no start codes")
	}
	starts = append(starts, len(b))
	auStart, key := -1, false
	for i := 0; i+1 < len(starts); i++ {
		nal := b[starts[i]:starts[i+1]]
		hdr := bytes.IndexByte(nal, 1) + 1
		typ := nal[hdr] & 0x1f
		if typ == 9 {
			if auStart >= 0 {
				c.video = append(c.video, b[auStart:starts[i]])
				c.key = append(c.key, key)
			}
			auStart, key = starts[i], false
		}
		if typ == 5 {
			key = true
		}
	}
	if auStart >= 0 {
		c.video = append(c.video, b[auStart:])
		c.key = append(c.key, key)
	}
	if len(c.video) == 0 || !c.key[0] {
		return errors.New("video.h264: needs AUDs and an IDR first (h264_metadata=aud=insert)")
	}
	return nil
}

// parseOgg collects the Opus packets of an Ogg stream, past OpusHead and
// OpusTags.
func (c *clip) parseOgg(b []byte) error {
	var pkt []byte
	n := 0
	for len(b) >= 27 {
		if string(b[:4]) != "OggS" {
			return errors.New("audio.opus: not Ogg")
		}
		segs := int(b[26])
		table := b[27 : 27+segs]
		body := b[27+segs:]
		off := 0
		for _, l := range table {
			pkt = append(pkt, body[off:off+int(l)]...)
			off += int(l)
			if l < 255 {
				if n >= 2 {
					c.audio = append(c.audio, pkt)
				}
				n++
				pkt = nil
			}
		}
		b = body[off:]
	}
	if len(c.audio) == 0 {
		return errors.New("audio.opus: no packets")
	}
	return nil
}

func (c *clip) String() string {
	var vb, ab int
	for _, f := range c.video {
		vb += len(f)
	}
	for _, p := range c.audio {
		ab += len(p)
	}
	return fmt.Sprintf("%d frames (GOP %d, %.2f Mbit/s), %d audio packets (%.0f kbit/s)",
		len(c.video), c.gop, float64(vb)*8/(float64(len(c.video))/30)/1e6,
		len(c.audio), float64(ab)*8/(float64(len(c.audio))*0.02)/1e3)
}
