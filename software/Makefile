.PHONY: udp_receiver wav_to_fpga test

udp_receiver:
	python3 udp_receiver/aces2_udp_receiver.py

wav_to_fpga:
	python3 audio_mock/wav_to_fpga.py $(WAV)

test:
	python3 -m unittest discover -s udp_receiver -p 'test_*.py' -v
