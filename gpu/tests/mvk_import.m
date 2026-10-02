#define VK_USE_PLATFORM_METAL_EXT 1
#define VK_ENABLE_BETA_EXTENSIONS 1
#import <Metal/Metal.h>
#include <vulkan/vulkan.h>
#include <vulkan/vulkan_metal.h>
#include <stdio.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#define C(x) do{VkResult r=(x); if(r){printf("%s=%d\n",#x,r);return 1;}}while(0)
int main(void){
  const char *exts[]={"VK_KHR_portability_enumeration"};
  VkApplicationInfo app={VK_STRUCTURE_TYPE_APPLICATION_INFO,.apiVersion=VK_API_VERSION_1_2};
  VkInstanceCreateInfo ici={VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,.pApplicationInfo=&app};
  VkInstance inst; C(vkCreateInstance(&ici,0,&inst));
  uint32_t n=1; VkPhysicalDevice pd; vkEnumeratePhysicalDevices(inst,&n,&pd);
  float pr=1; VkDeviceQueueCreateInfo q={VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,.queueCount=1,.pQueuePriorities=&pr};
  const char *dexts[]={"VK_EXT_external_memory_metal","VK_EXT_metal_objects","VK_KHR_portability_subset"};
  VkDeviceCreateInfo dci={VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,.queueCreateInfoCount=1,.pQueueCreateInfos=&q,.enabledExtensionCount=3,.ppEnabledExtensionNames=dexts};
  VkDevice dev; C(vkCreateDevice(pd,&dci,0,&dev));
  PFN_vkExportMetalObjectsEXT ex=(void*)vkGetDeviceProcAddr(dev,"vkExportMetalObjectsEXT");
  VkExportMetalDeviceInfoEXT di={VK_STRUCTURE_TYPE_EXPORT_METAL_DEVICE_INFO_EXT};
  VkExportMetalObjectsInfoEXT ei={VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT,.pNext=&di};
  ex(dev,&ei); id<MTLDevice> md=di.mtlDevice; printf("mtl device %s\n",[[md name] UTF8String]);
  size_t sz=1<<20; int fd=shm_open("/mvktest",O_CREAT|O_RDWR,0600); shm_unlink("/mvktest"); ftruncate(fd,sz);
  uint32_t *p=mmap(0,sz,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
  uint32_t *p2=mmap(0,sz,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
  id<MTLBuffer> b=[md newBufferWithBytesNoCopy:p length:sz options:MTLResourceStorageModeShared deallocator:nil];
  VkPhysicalDeviceMemoryProperties mp; vkGetPhysicalDeviceMemoryProperties(pd,&mp);
  uint32_t mt=0; for(uint32_t i=0;i<mp.memoryTypeCount;i++){ if((mp.memoryTypes[i].propertyFlags&6)==6){mt=i;break;} }
  VkImportMemoryMetalHandleInfoEXT imp={VK_STRUCTURE_TYPE_IMPORT_MEMORY_METAL_HANDLE_INFO_EXT,.handleType=VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLBUFFER_BIT_EXT,.handle=(__bridge void*)b};
  VkMemoryAllocateInfo ai={VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,.pNext=&imp,.allocationSize=sz,.memoryTypeIndex=mt};
  VkDeviceMemory mem; C(vkAllocateMemory(dev,&ai,0,&mem));
  VkBufferCreateInfo bi={VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,.size=sz,.usage=VK_BUFFER_USAGE_TRANSFER_DST_BIT};
  VkBuffer buf; C(vkCreateBuffer(dev,&bi,0,&buf)); C(vkBindBufferMemory(dev,buf,mem,0));
  VkCommandPoolCreateInfo cpi={VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO}; VkCommandPool pool; C(vkCreateCommandPool(dev,&cpi,0,&pool));
  VkCommandBufferAllocateInfo cai={VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,.commandPool=pool,.commandBufferCount=1}; VkCommandBuffer cb; C(vkAllocateCommandBuffers(dev,&cai,&cb));
  VkCommandBufferBeginInfo bb={VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO}; vkBeginCommandBuffer(cb,&bb);
  vkCmdFillBuffer(cb,buf,0,sz,0x12345678); vkEndCommandBuffer(cb);
  VkQueue qu; vkGetDeviceQueue(dev,0,0,&qu); VkSubmitInfo si={VK_STRUCTURE_TYPE_SUBMIT_INFO,.commandBufferCount=1,.pCommandBuffers=&cb};
  C(vkQueueSubmit(qu,1,&si,0)); vkQueueWaitIdle(qu);
  void *vm; vkMapMemory(dev,mem,0,sz,0,&vm);
  printf("p[0]=%x p2[0]=%x vkmap[0]=%x vkmap==p %d\n",p[0],p2[0],((uint32_t*)vm)[0], vm==p);
  return 0;}
