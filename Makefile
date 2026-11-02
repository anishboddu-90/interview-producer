.PHONY: all test live-test app run
all: app
app:
	./Scripts/build-app.sh
test:
	swift build -c debug --disable-index-store -j 2
	.build/debug/InterviewProducer --self-test
live-test:
	swift build -c debug --disable-index-store -j 2
	.build/debug/InterviewProducer --live-scenarios
run: app
	open 'dist/Interview Producer.app'

.PHONY: memory-test
memory-test:
	swift build -c debug --disable-index-store -j 2
	.build/debug/InterviewProducer --memory-test

.PHONY: story-test story-live-test
story-test:
	swift build -c debug --disable-index-store -j 2
	.build/debug/InterviewProducer --story-test
story-live-test:
	swift build -c debug --disable-index-store -j 2
	.build/debug/InterviewProducer --story-live-test

.PHONY: lifeline-test lifeline-live-test
lifeline-test:
	swift build -c debug --disable-index-store -j 2
	.build/debug/InterviewProducer --lifeline-test
lifeline-live-test:
	swift build -c debug --disable-index-store -j 2
	.build/debug/InterviewProducer --lifeline-live-test

.PHONY: integration-test cloud-rehearsal native-capture-test
integration-test:
	swift build -c debug --disable-index-store -j 2
	.build/debug/InterviewProducer --integration-test
# Use the signed application so macOS can associate permissions with its bundle.
# REHEARSAL_AUDIO must contain the five generated WAVs described in REHEARSAL.md.
cloud-rehearsal: app
	'dist/Interview Producer.app/Contents/MacOS/InterviewProducer' --full-live-rehearsal --rehearsal-audio "$(REHEARSAL_AUDIO)" --rehearsal-output 'dist/Cloud-Rehearsal'
native-capture-test: app
	'dist/Interview Producer.app/Contents/MacOS/InterviewProducer' --native-capture-test

.PHONY: shortcut-os-test
shortcut-os-test:
	bash Scripts/test-shortcut-conflict.sh
