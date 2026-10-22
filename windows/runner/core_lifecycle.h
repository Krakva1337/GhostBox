#ifndef RUNNER_CORE_LIFECYCLE_H_
#define RUNNER_CORE_LIFECYCLE_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/binary_messenger.h>
#include <windows.h>
#include <memory>

// Only VPN cores are assigned to this job. Updaters and URL handlers remain
// independent; Windows terminates the cores if the UI crashes or is killed.
class CoreLifecycle {
 public:
  explicit CoreLifecycle(flutter::BinaryMessenger* messenger);
  ~CoreLifecycle();
  CoreLifecycle(const CoreLifecycle&) = delete;
  CoreLifecycle& operator=(const CoreLifecycle&) = delete;
 private:
  HANDLE job_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};
#endif
