//
//  ViewController.m
//  TuHLSPlayer
//
//  Created by zhantu wu on 2026/9/21.
//

#import "ViewController.h"

@interface ViewController ()

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    [self parseTSFile];
}

- (void)parseTSFile {
    NSString *tsPath = [[NSBundle mainBundle] pathForResource:@"fileSequence5" ofType:@"ts"];
    NSData *tsData = [NSData dataWithContentsOfFile:tsPath];
    uint8_t *tsBytes = (uint8_t *)malloc(tsData.length);
    [tsData getBytes:tsBytes length:tsData.length];
    
    int offset = 0;
    int segmentCount = 0;
    while (segmentCount < 10) {
        if (tsBytes[offset] == 0x47) {
            ++segmentCount;
            NSLog(@"片段%d: ", segmentCount);
            uint8_t byte2 = tsBytes[offset+1];
            uint8_t byte3 = tsBytes[offset+2];
            BOOL pusi = (byte2 & 0x40) != 0;
            int pid = ((byte2 & 0x1F) << 8) + byte3;
            NSLog(@"pusi %d pid %x", pusi, pid);
        }
        offset += 188;
    }
}


@end
