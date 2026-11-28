#ifndef SOLARA_CORE_AC_EXTERNAL_APPS_H_
#define SOLARA_CORE_AC_EXTERNAL_APPS_H_

#import <Foundation/Foundation.h>

#include <string>

namespace content {
class WebContents;
}

namespace solaracore {

void InstallExternalAppPrompts();
void RetireStaleExternalApps(content::WebContents* closing);
void ResolveExternalApp(const std::string& request_id, bool open, bool remember);
NSArray<NSDictionary*>* TestExternalLaunches();
bool TestNoLaunch();
void RecordTestLaunch(NSDictionary* launch);

}

#endif
