#ifndef SYSTEM_HPP__
#define SYSTEM_HPP__

#include "map.h"
#include "viewer.h"
#include "tracker.h"

#include <mutex>
#include <thread>
#include <future>

class Viewer;
class Mapping;
class tracker;

struct SysDesc {
	int cols, rows;
	float fx;
	float fy;
	float cx;
	float cy;
	float DepthCutoff;
	float DepthScale;
	bool TrackModel;
	std::string path;
	bool bUseDataset;
};

class System {
public:
	System(const char* str);
	System(SysDesc* pParam);
	bool grabImage(cv::Mat& imRGB, cv::Mat& imD);
	void SetParameters(SysDesc& desc);
	void PrintTimings();
	void JoinViewer();
	void saveMesh();
	void reboot();

public:
	Mapping* mpMap;
	Viewer* mpViewer;
	SysDesc* mpParam;
	tracker* mpTracker;

	cv::Mat mK;
	int nFrames;
	std::thread* mptViewer;

	std::mutex mutexReq;
	bool requestSaveMesh;
	bool requestReboot;
	bool requestStop;
};

#endif