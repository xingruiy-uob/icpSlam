#include "Timer.hpp"

using namespace std;

map<string, map<string, chrono::high_resolution_clock::time_point>> Timer::mTable;
map<string, map<string, int>> Timer::mDuration;
bool Timer::bEnabled = false;

void Timer::AddCategory(string str) {
	mTable[str] = map<string, chrono::high_resolution_clock::time_point>();
	mDuration[str] = map<string, int>();
}

void Timer::Enable() {
	bEnabled = true;
}

void Timer::Disable() {
	bEnabled = false;
}

void Timer::Start(const string cat, const string str) {
	if(!bEnabled)
		return;

	if (!mTable.count(cat))
		AddCategory(cat);

	auto& iter = mTable[cat];
	iter[str] = chrono::high_resolution_clock::now();
}

void Timer::Stop(const string cat, const string str) {
	if(!bEnabled)
		return;

	if (!mTable.count(cat) || !mTable[cat].count(str))
		return;

	auto t = chrono::high_resolution_clock::now();
	auto dt = chrono::duration_cast<chrono::microseconds>(t - mTable[cat][str]);

	mDuration[cat][str] = dt.count();
}

void Timer::Print() {
	if(!bEnabled)
		return;

	int counter = 1;
	map<string, map<string, int>>::iterator iter = mDuration.begin();
	map<string, map<string, int>>::iterator lend = mDuration.end();

	cout << "------------------------------------------" << endl;
	cout << "Timer Readings: " << endl;
	for (; iter != lend; ++iter) {

		int total_time = 0;
		int inner_counter = 1;

		map<string, int>::iterator inner_iter = mDuration[iter->first].begin();
		map<string, int>::iterator inner_lend = mDuration[iter->first].end();
		for (; inner_iter != inner_lend; ++inner_iter) {
			total_time += inner_iter->second;
		}

		string unit;
		if(total_time >= 1000) {
			total_time /= 1000;
			unit = " ms";
		}
		else
			unit = " us";

		cout << counter++
			 << ". " << iter->first << " : "
			 << total_time << unit << endl;

		inner_iter = mDuration[iter->first].begin();
		for (; inner_iter != inner_lend; ++inner_iter) {
			int time = inner_iter->second;
			if (time >= 1000) {
				time /= 1000;
				unit = " ms";
			} else
				unit = " us";

			cout << "\t"
				 << inner_counter++ << ". "
				 << inner_iter->first
			     << " : "
			     << time
			     << unit << endl;
		}
	}
}