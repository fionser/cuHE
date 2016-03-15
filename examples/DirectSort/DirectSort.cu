/*
The MIT License (MIT)

Copyright (c) 2015 Wei Dai

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

#include "circ_sorting.h"
#include "../doc/config.h"
#include "../include/timer.h"
#include "omp.h"
#include <algorithm>

DirectSort::DirectSort() {
	level = 0;
	sortSize = 8;
	circuitDepth = 0;
	minCoeffSize = 0;
	randList = new int[sortSize];
	CtxtInt list = new CtxtInt[sortSize];
	sortedList = new int[sortSize];
	checkList = new int[sortSize];
	createTempResults();
}

DirectSort::DirectSort(int val) {
	level = 0;
	sortSize = val;
	circuitDepth = 0;
	minCoeffSize = 0;
	randList = new int[sortSize];
	CtxtInt list = new CtxtInt[sortSize];
	sortedList = new int[sortSize];
	checkList = new int[sortSize];
	createTempResults();
}

DirectSort::~DirectSort() {
	delete [] randList;
	delete [] list;
	delete [] sortedList;
	delete [] checkList;
	delete cudhs;
	for (int i=0; i<numComputeDevices; i++) {
		for (int j=0; j<sortSize; j++) {
			delete [] cI[i][j];
			delete [] cS[i][j];
		}
		delete [] cI[i];
		delete [] cS[i];
		delete [] cO[i];
		delete [] cT[i];
	}
	delete [] cI;
	delete [] cS;
	delete [] cT;
	delete [] cO;
	delete [] cE;
}

void DirectSort::heSetup() {
	multiGPUs(1);
	cudhs = new CuDHS(circuitDepth, 2, 16, minCoeffSize, minCoeffSize, 8191);
}

void DirectSort::setList() {
	for (int i=0; i<sortSize; i++)
		randList[i] = rand()%1000;
}

void DirectSort::encList() {
	for (int i=0; i<sortSize; i++) {
		for(int j=0; j<32; j++) {
			list[i].bit[j].bit = (randList[i]>>j)%2;
			list[i].bit[j].bit = cuhe->encrypt(list[i].bit[j].bit, level);
		}
	}
}

void DirectSort::decList() {
	for (int i=0; i<sortSize; i++) {
		sortedList[i] = 0;
		for(int j=0; j<32; j++) {
			list[i].bit[j].bit = cuhe->decrypt(list[i].bit[j].bit, level);
			sortedList[i] += to_long(coeff(list[i].bit[j].bit, 0)<<j);
		}
	}
}

void DirectSort::trueSort() {
	for (int i=0; i<sortSize; i++)
		checkList[i] = randList[i];
	sort(checkList, checkList+sortSize);
}

void DirectSort::printList (int ptr[sortSize]) {
	for (int i=0; i<sortSize; i++)
		cout<<ptr[i]<<"\t";
	cout<<endl;
}

void DirectSort::test() {
	cout<<"---------- Precomputation --------"<<endl;
	heSetup();
	cout<<"---------- Encrypt List ----------"<<endl;
	setList();
	encList();
	cout<<"---------- Direct Sort -----------"<<endl;
	otimer ot;
	ot.start();
	mysort();
	ot.stop();
	ot.show("Sort Time");
	cout<<"---------- Decrypt List ----------"<<endl;
	decList();
	trueSort();
	cout<<"Input:  ";
	printList(randList);
	cout<<"Expect: ";
	printList(checkList);
	cout<<"Output: ";
	printList(sortedList);
}

void DirectSort::createTempResults() {
	cI = new CuCtxt **[numComputeDevices];// input list
	cM = new CuCtxt **[numComputeDevices];// comparison matrix
	cS = new CuCtxt **[numComputeDevices];// hammingweights or rankings
	cO = new CuCtxt *[numComputeDevices];// output list
	cE = new CuCtxt[numComputeDevices];// temp
	cT = new CuCtxt *[numComputeDevices];// temp
	for (int dev=0; dev<numComputeDevices; dev++) {
		cI[dev] = new CuCtxt *[sortSize];
		cM[dev] = new CuCtxt *[sortSize];
		cS[dev] = new CuCtxt *[sortSize];
		for (int i=0; i<sortSize; i++) {
			cI[dev][i] = new CuCtxt[32];
			cM[dev][i] = new CuCtxt[sortSize];
			cS[dev][i] = new CuCtxt[8];
		}
		cO[dev] = new CuCtxt[32];
		cT[dev] = new CuCtxt[8];
	}
}

void DirectSort::prepareInput() {
	otimer ot;
	ot.start();
	#pragma omp parallel num_threads(numComputeDevices)
	{
		int nowDev = omp_get_thread_num();
//		int nowDev = 0;
		for (int k=0; k<sortSize*32; k++) {
			int i = k/32, j = k%32;
			if (k%numComputeDevices == nowDev) {
				cI[nowDev][i][j].set(level, nowDev, 0, list[i].bit[j].bit);
				cI[nowDev][i][j].x2c();
			}
			else {
				cI[nowDev][i][j].set(level, nowDev, 2);
			}
		}
		#pragma omp barrier
		for (int k=0; k<sortSize*32; k++) {
			int i = k/32, j = k%32;
			if (k%numComputeDevices == nowDev) {
				for (int dev=0; dev<numComputeDevices; dev++)
					if (dev != nowDev)
						cI[nowDev][i][j].copyToDevice(cI[dev][i][j]);
			}
		}
	}
	ot.stop();
	ot.show("Input");
}

void DirectSort::constructMatrix() {
	otimer ot;
	ot.start();
//	#pragma omp parallel num_threads(1)
//	#pragma omp parallel num_threads(2)
	#pragma omp parallel num_threads(3)
//	#pragma omp parallel num_threads(numComputeDevices)
	{
		int nowDev = omp_get_thread_num();
//		int nowDev = 0;
		int cnt = 0;
		/* ! double copy of cM, must be a way to avoid ! */
		for (int i=0; i<sortSize; i++) {
			cM[nowDev][i][i].set(level+6, nowDev, 2);// set crt domain empty ctext
			for (int j=i+1; j<sortSize; j++) {
				if (cnt%omp_get_num_threads() == nowDev) {
					isLess(cM[nowDev][j][i], cI[nowDev][i], cI[nowDev][j]);
					cM[nowDev][i][j] = cM[nowDev][j][i]+1;
				}
				else {
					cM[nowDev][i][j].set(level+6, nowDev, 2);
					cM[nowDev][j][i].set(level+6, nowDev, 2);
				}
				cnt ++;
			}
		}/* ! ! */
		#pragma omp barrier
		cnt = 0;
		for (int i=0; i<sortSize; i++) {
			for (int j=i+1; j<sortSize; j++) {
				if (cnt%omp_get_num_threads() == nowDev) {
					for (int dev=0; dev<numComputeDevices; dev++) {
						if (dev != nowDev) {
							cM[nowDev][j][i].copyToDevice(cM[dev][j][i]);
							cM[nowDev][i][j].copyToDevice(cM[dev][i][j]);
						}
					}
				}
				cnt ++;
			}
		}
	}
	level += 6;
	ot.stop();
	ot.show("Matrix");
}

void DirectSort::hammingWeights() {
	otimer ot;
	ot.start();
	// (sortSize, levelup) = (4, 1) (8, 2) (16, 3) (32, 4) (64, 5)
	int tempLevel = level;
	int sortSizeIter = sortSize/4;
	while (sortSizeIter > 0) {
		tempLevel ++;
		sortSizeIter /= 2;
	}
//	#pragma omp parallel num_threads(1)
//	#pragma omp parallel num_threads(2)
	#pragma omp parallel num_threads(3)
//	#pragma omp parallel num_threads(numComputeDevices)
	{
		int nowDev = omp_get_thread_num();
//		int nowDev = 0;
		for (int i=0; i<sortSize; i++) {
			if (i%numComputeDevices == nowDev) {
				calHW(cS[nowDev][i], cM[nowDev][i]);
			}
			else {
				for (int j=0; j<8; j++) {
					cS[nowDev][i][j].set(tempLevel, nowDev, 2);
				}
			}
		}
		#pragma omp barrier
		for (int i=0; i<sortSize; i++) {
			for (int dev=0; dev<numComputeDevices; dev++) {
				if (i%numComputeDevices == nowDev) {
					if (dev != nowDev) {
						for (int j=0; j<8; j++) {
							cS[nowDev][i][j].copyToDevice(cS[dev][i][j]);
						}
					}
				}
			}
		}
	}
	ot.stop();
	ot.show("HWs");
	level = tempLevel;
}

void DirectSort::prepareOutput() {
	otimer ot;
	ot.start();
//	#pragma omp parallel num_threads(1)
//	#pragma omp parallel num_threads(2)
	#pragma omp parallel num_threads(3)
//	#pragma omp parallel num_threads(numComputeDevices)
	{
		int nowDev = omp_get_thread_num();
//		int nowDev = 0;
		// raise cI
		for (int k=0; k<sortSize*32; k++) {
			int i = k/32, j = k%32;
			if (k%numComputeDevices == nowDev) {
				cI[nowDev][i][j].raiseToLevel(level+3);	// isEqual has 3 levels
				cI[nowDev][i][j].x2n();
			}
			else {
				cI[nowDev][i][j].set(level+3, nowDev, 3);
			}
		}
		#pragma omp barrier
		for (int k=0; k<sortSize*32; k++) {
			int i = k/32, j = k%32;
			if (k%numComputeDevices == nowDev) {
				for (int dev=0; dev<numComputeDevices; dev++) {
					if (dev != nowDev) {
						cI[nowDev][i][j].copyToDevice(cI[dev][i][j]);
					}
				}
			}
		}
		#pragma omp barrier
		// check ranking and compute output
		#pragma omp for
		for (int i=0; i<sortSize; i++) {
			for (int j=0; j<32; j++) {
				cO[nowDev][j].set(level+3, nowDev, 2);
			}
			for (int j=0; j<8; j++) {
				ZZX temp;
				SetCoeff(temp, 0, (i>>j)%2);
				cT[nowDev][j].set(level, nowDev, 0, temp);
				cT[nowDev][j].x2c();
			}
			for (int j=0; j<sortSize; j++) {
				isEqual(cE[nowDev], cT[nowDev], cS[nowDev][j]);
				for (int k=0; k<32; k++) {
					cE[nowDev].x2n();
					cO[nowDev][k] = cO[nowDev][k]+(cI[nowDev][j][k]*cE[nowDev]);
				}
			}
			for (int j=0; j<32; j++) {
				cO[nowDev][j].relin();
				cO[nowDev][j].modSwitch();
			}
			for (int j=0; j<32; j++) {
				cO[nowDev][j].x2z();
				list[i].bit[j].bit = cO[nowDev][j].zRepGet();
			}
		}
	}
	ot.stop();
	ot.show("RankOutput");
	level += 3;	// isEqual has 3 levels
	level += 1; // AND gates
}

void DirectSort::mysort() {
	prepareInput();
/*	cudaDeviceSynchronize();
	cout<<"cI:"<<endl;
	for (int i=0; i<sortSize; i++) {
		sortedList[i] = 0;
		for(int j=0; j<32; j++) {
			cI[0][i][j].x2z();
			list[i].bit[j].bit = cuhe->decrypt(cI[0][i][j].zRepGet(), level);
			sortedList[i] += to_long(coeff(list[i].bit[j].bit, 0)<<j);
			cI[0][i][j].x2c();
		}
		cout<<sortedList[i]<<" ";
	}
	cout<<endl;
*/

	constructMatrix();
/*	cudaDeviceSynchronize();
	cout<<"cM:"<<endl;
	for (int i=0; i<sortSize; i++) {
		for(int j=0; j<sortSize; j++) {
			cM[0][i][j].x2z();
			cout<<coeff(cuhe->decrypt(cM[0][i][j].zRepGet(), level), 0);
			cM[0][i][j].x2c();
		}
		cout<<endl;
	}
*/

	hammingWeights();
/*	cudaDeviceSynchronize();
	cout<<"cS:"<<endl;
	for (int i=0; i<sortSize; i++) {
		sortedList[i] = 0;
		for(int j=0; j<8; j++) {
			cS[0][i][j].x2z();
			list[i].bit[j].bit = cuhe->decrypt(cS[0][i][j].zRepGet(), level);
			sortedList[i] += to_long(coeff(list[i].bit[j].bit, 0)<<j);
			cS[0][i][j].x2c();
		}
		cout<<sortedList[i]<<endl;
	}
*/

	prepareOutput();
//	cudaDeviceSynchronize();
}

void DirectSort::isLess(CuCtxt &res, CuCtxt *a, CuCtxt *b) {
	CuCtxt y;
	CuCtxt m[32], t[32];
	// set & lvl 1
	for (int i=0; i<32; i++) {
		y = b[i];
		m[i] = a[i]+1;
		t[i] = m[i]+y;
		m[i].x2n();
		y.x2n();
		m[i] *= y;
		m[i].relin();
	}
	// lvl 1~5
	for (int i=1; i<6; i++) {
		int e = 0x1<<i;
		for (int j=e; j<32; j+=e) {
			t[j].x2n();
			t[j+e/2].x2n();
			t[j] *= t[j+e/2];
			t[j].relin();
		}
		e *= 2;
		// only these values are used later
		for (int j=e/4-1; j<32; j+=e/4)
			m[j].modSwitch();
		for (int j=e/4; j<32; j+=e/2)
			t[j].modSwitch();
		for (int j=e/2; j<32; j+=e/2)
			t[j].modSwitch();

		for (int j=e/4-1; j<32; j+=e/2) {
			m[j].x2n();
			t[j+1].x2n();
			m[j] *= t[j+1];
			m[j].relin();
		}
		for (int j=e/2-1; j<32; j+=e/2) {
			m[j].x2c();
			m[j-e/4].x2c();
			m[j] += m[j-e/4];
		}
	}
	// lvl 6
	m[31].modSwitch();
	res = m[31];
}

void DirectSort::isEqual(CuCtxt &res, CuCtxt *a, CuCtxt *b) {
	CuCtxt t[8];
	for (int i=0; i<8; i++) {
		t[i] = a[i]+b[i]+1;
	}
	// level 1,2,3
	int cnt = 8;
	for (int i=0; i<3; i++) {
		cnt /= 2;
		for (int j=0; j<cnt; j++) {
			t[j].x2n();
			t[j+cnt].x2n();
			t[j] *= t[j+cnt];
			t[j].relin();
			t[j].modSwitch();
		}
	}
	res = t[0];
}

void DirectSort::calHW(CuCtxt *s, CuCtxt *m) {
	if (sortSize == 4)
		calHW4(s, m);
	else if (sortSize == 8)
		calHW8(s, m);
	else if (sortSize == 16)
		calHW16(s, m);
	else if (sortSize == 32)
		calHW32(s, m);
	else if (sortSize == 64)
		calHW64(s, m);
	else {
		cout<<"wrong HammingWeight sortSize"<<endl;
		terminate();
	}
}

void DirectSort::calHW4(CuCtxt *s, CuCtxt *m) {
	int lvl = level;
	for (int i=0; i<4; i++)
		m[i].x2c();
	CuCtxt s1 = m[0]+m[1]+m[2];
	s[0] = s1+m[3];

    // Depth 1
	for (int i=0; i<4; i++)
		m[i].x2n();
	CuCtxt c1 = (m[0]*m[1])+(m[0]*m[2])+(m[1]*m[2]);
	s1.x2n();
	CuCtxt c2 = s1*m[3];
	s[1] = c1 + c2;

	// Finalize
	s[1].relin();
	s[1].modSwitch();
	lvl++;
	s[0].raiseToLevel(lvl);
	for (int i=2; i<8; i++)
		s[i].set(s[0].levelGet(), s[0].deviceGet(), s[0].domainGet());
}

void DirectSort::calHW8(CuCtxt *s, CuCtxt *m) {
	int lvl = level;
	for (int i=0; i<8; i++)
		m[i].x2c();
	CuCtxt s1 = m[0]+m[1]+m[2];
	CuCtxt s2 = m[3]+m[4]+m[5];
	CuCtxt s3 = m[6]+m[7];
	s[0] = s1+s2+s3;
	// depth 1

	for (int i=0; i<8; i++)
		m[i].x2n();
	CuCtxt c1 = (m[0]*m[1])+(m[0]*m[2])+(m[1]*m[2]);
	c1.relin();
	c1.modSwitch();
	CuCtxt c2 = (m[3]*m[4])+(m[3]*m[5])+(m[4]*m[5]);
	c2.relin();
	c2.modSwitch();
	CuCtxt c3 = m[6]*m[7];
	c3.relin();
	c3.modSwitch();
	CuCtxt s21 = c1+c2+c3;
	s1.x2n();
	s2.x2n();
	s3.x2n();
	CuCtxt c11 = (s1*s2)+(s1*s3)+(s2*s3);
	c11.relin();
	c11.modSwitch();
	s[1] = s21+c11;
	lvl ++;

	//depth 2
	c1.x2n();
	c2.x2n();
	c3.x2n();
	s21.x2n();
	c11.x2n();
	CuCtxt c21 = (c1*c2)+(c2*c3)+(c1*c3);
	CuCtxt c22 = s21*c11;
	s[2] = c21+c22;
	s[2].relin();
	s[2].modSwitch();
	lvl ++;
	s[0].raiseToLevel(lvl);
	s[1].raiseToLevel(lvl);
	for (int i=3; i<8; i++)
		s[i].set(s[0].levelGet(), s[0].deviceGet(), s[0].domainGet());
}

void DirectSort::calHW16(CuCtxt *s, CuCtxt *m) {
	int lvl = level;
	for (int i=0; i<16; i++)
		m[i].x2c();

	// depth 1
	CuCtxt t[6], c[6];
	for (int i=0; i<4; i++)
		t[i] = m[3*i]+m[3*i+1]+m[3*i+2];
	t[4] = m[12]+m[13];
	t[5] = m[14]+m[15];
	for (int i=0; i<16; i++)
		m[i].x2n();
	for (int i=0; i<4; i++)
		c[i] = (m[3*i]*m[3*i+1])+(m[3*i]*m[3*i+2])+(m[3*i+1]*m[3*i+2]);
	c[4] = m[12]*m[13];
	c[5] = m[14]*m[15];
	for (int i=0; i<6; i++) {
		c[i].relin();
		c[i].modSwitch();
	}

	CuCtxt t1 = t[0]+t[1]+t[2];
	CuCtxt t2 = t[3]+t[4]+t[5];
	CuCtxt t3 = c[0]+c[1]+c[2];
	CuCtxt t4 = c[3]+c[4]+c[5];

	for (int i=0; i<3; i++)
		t[i].x2n();
	CuCtxt c1 = (t[0]*t[1])+(t[0]*t[2])+(t[1]*t[2]);
	c1.relin();
	c1.modSwitch();
	t[0].x2c();
	t[0] = t3+t4+c1;
	for (int i=3; i<6; i++)
		t[i].x2n();
	t[1] = (t[3]*t[4])+(t[3]*t[5])+(t[4]*t[5]);
	t[1].relin();
	t[1].modSwitch();
	s[0] = t1+t2;
	t1.x2n();
	t2.x2n();
	t[2] = t1*t2;
	t[2].relin();
	t[2].modSwitch();
	s[1] = t[0]+t[1]+t[2];
	lvl ++;
	// depth 2
	for (int i=0; i<6; i++)
		c[i].x2n();
	t3.x2n();
	t4.x2n();
	c1.x2n();
	for (int i=0; i<3; i++)
		t[i].x2n();
	c[0] = (c[0]*c[1])+(c[0]*c[2])+(c[1]*c[2]);
	c[1] = (c[3]*c[4])+(c[3]*c[5])+(c[4]*c[5]);
	c[2] = (t3*t4)+(t3*c1)+(t4*c1);
	c[3] = (t[0]*t[1])+(t[0]*t[2])+(t[1]*t[2]);
	for (int i=0; i<4; i++) {
		c[i].relin();
		c[i].modSwitch();
	}
	t1 = c[0]+c[1];
	t2 = c[2]+c[3];
	s[2] = t1+t2;
	lvl ++;

	// depth 3
	for (int i=0; i<4; i++)
		c[i].x2n();
	t1.x2n();
	t2.x2n();
	c[0] *= c[1];
	c[1] = c[2]*c[3];
	c[2] = t1*t2;
	for (int i=0; i<3; i++)
		c[i].relin();
	s[3] = c[0]+c[1]+c[2];
//	s[3].relin();
	lvl ++;
	for (int i=0; i<4; i++)
		s[i].raiseToLevel(lvl);
	for (int i=4; i<8; i++)
		s[i].set(s[0].levelGet(), s[0].deviceGet(), s[0].domainGet());
}

void DirectSort::calHW32(CuCtxt *s, CuCtxt *m) {
	int lvl = level;
	for (int i=0; i<32; i++)
		m[i].x2c();

	// depth 1
	CuCtxt t[12], c[10];
	for (int i=0; i<10; i++)
		t[i] = m[3*i]+m[3*i+1]+m[3*i+2];
	t[10] = m[30];
	t[11] = m[31];
	for (int i=0; i<32; i++)
		m[i].x2n();
	for (int i=0; i<10; i++) {
		c[i] = (m[3*i]*m[3*i+1])+(m[3*i]*m[3*i+2])+(m[3*i+1]*m[3*i+2]);
		c[i].relin();
		c[i].modSwitch();
	}
	CuCtxt t2[4], c2[8];
	c2[0] = c[9];
	for (int i=0; i<4; i++)
		t2[i] = t[3*i]+t[3*i+1]+t[3*i+2];
	for (int i=0; i<12; i++)
		t[i].x2n();
	for (int i=0; i<4; i++)
		c2[i+1] = (t[3*i]*t[3*i+1])+(t[3*i]*t[3*i+2])+(t[3*i+1]*t[3*i+2]);
	t[0] = t2[0]+t2[1];
	t[1] = t2[2]+t2[3];
	s[0] = t[0]+t[1];
	for (int i=0; i<4; i++)
		t2[i].x2n();
	t[0].x2n();
	t[1].x2n();
	c2[5] = t2[0]*t2[1];
	c2[6] = t2[2]*t2[3];
	c2[7] = t[0]*t[1];
	for (int i=1; i<8; i++) {
		c2[i].relin();
		c2[i].modSwitch();
	}
	lvl ++;

	// depth 2
	for (int i=0; i<3; i++)
		t[i] = c[3*i]+c[3*i+1]+c[3*i+2];
	for (int i=0; i<9; i++)
		c[i].x2n();
	for (int i=0; i<3; i++)
		c[i] = (c[3*i]*c[3*i+1])+(c[3*i]*c[3*i+2])+(c[3*i+1]*c[3*i+2]);
	for (int i=0; i<2; i++)
		t[i+3] = c2[3*i]+c2[3*i+1]+c2[3*i+2];
	t[5] = c2[6]+c2[7];
	for (int i=0; i<8; i++)
		c2[i].x2n();
	for (int i=0; i<2; i++)
		c[i+3] = (c2[3*i]*c2[3*i+1])+(c2[3*i]*c2[3*i+2])+(c2[3*i+1]*c2[3*i+2]);
	c[5] = c2[6]*c2[7];
	for (int i=0; i<6; i++) {
		c[i].relin();
		c[i].modSwitch();
	}
	t2[0] = t[0]+t[1]+t[2];
	t2[1] = t[3]+t[4]+t[5];
	s[1] = t2[0]+t2[1];
	for (int i=0; i<6; i++)
		t[i].x2n();
	t[0] = (t[0]*t[1])+(t[0]*t[2])+(t[1]*t[2]);
	t[0].relin();
	t[0].modSwitch();
	t[1] = (t[3]*t[4])+(t[3]*t[5])+(t[4]*t[5]);
	t[1].relin();
	t[1].modSwitch();
	t[2] = c[0]+c[1]+c[2];
	t[3] = c[3]+c[4]+c[5];
	t2[0].x2n();
	t2[1].x2n();
	t[4] = t2[0]*t2[1];
	t[4].relin();
	t[4].modSwitch();
	lvl ++;

	// depth 3
	for (int i=0; i<6; i++)
		c[i].x2n();
	for (int i=0; i<5; i++)
		t[i].x2n();
	c[0] = (c[0]*c[1])+(c[0]*c[2])+(c[1]*c[2]);
	c[1] = (c[3]*c[4])+(c[3]*c[5])+(c[4]*c[5]);
	c[2] = (t[0]*t[1])+(t[0]*t[2])+(t[1]*t[2]);
	c[3] = t[3]*t[4];
	for (int i=0; i<5; i++)
		t[i].x2c();
	t[0] = t[0]+t[1]+t[2];
	t[1] = t[3]+t[4];
	s[2] = t[0]+t[1];
	t[0].x2n();
	t[1].x2n();
	c[4] = t[0]*t[1];
	for (int i=0; i<5; i++) {
		c[i].relin();
		c[i].modSwitch();
	}
	t[0] = c[0]+c[1]+c[2];
	t[1] = c[3]+c[4];
	s[3] = t[0]+t[1];
	lvl ++;

	// depth 4
	for (int i=0; i<5; i++)
		c[i].x2n();
	t[0].x2n();
	t[1].x2n();
	c[0] = (c[0]*c[1])+(c[0]*c[2])+(c[1]*c[2]);
	c[1] = c[3]*c[4];
	c[2] = t[0]*t[1];
	s[4] = c[0]+c[1]+c[2];
	s[4].relin();
	lvl ++;
	for (int i=0; i<5; i++)
		s[i].raiseToLevel(lvl);
	for (int i=5; i<8; i++)
		s[i].set(s[0].levelGet(), s[0].deviceGet(), s[0].domainGet());
}

void DirectSort::calHW64(CuCtxt *s, CuCtxt *m) {
	int lvl = level;
	CuCtxt a[22], b[21], c[11];

	// depth 1
	for (int i=0; i<64; i++)
		m[i].x2c();
	for (int i=0; i<21; i++)
		a[i] = m[3*i]+m[3*i+1]+m[3*i+2];
	a[21] = m[63];
	for (int i=0; i<64; i++)
		m[i].x2n();
	for (int i=0; i<21; i++) {
		b[i] = (m[3*i]*m[3*i+1])+(m[3*i]*m[3*i+2])+(m[3*i+1]*m[3*i+2]);
		b[i].relin();
		b[i].modSwitch();
	}
	for (int i=0; i<21; i++)
		a[i].x2n();
	for (int i=0; i<7; i++) {
		c[i] = (a[3*i]*a[3*i+1])+(a[3*i]*a[3*i+2])+(a[3*i+1]*a[3*i+2]);
		c[i].relin();
		c[i].modSwitch();
	}
	for (int i=0; i<22; i++)
		a[i].x2c();
	for (int i=0; i<7; i++)
		a[i] = a[3*i]+a[3*i+1]+a[3*i+2];
	a[7] = a[21];
	for (int i=0; i<8; i++)
		a[i].x2n();
	c[7] = (a[0]*a[1])+(a[0]*a[2])+(a[1]*a[2]);
	c[8] = (a[3]*a[4])+(a[3]*a[5])+(a[4]*a[5]);
	c[9] = a[6]*a[7];
	for (int i=7; i<10; i++) {
		c[i].relin();
		c[i].modSwitch();
	}
	for (int i=0; i<8; i++)
		a[i].x2c();
	a[0] += (a[1]+a[2]);
	a[1] += (a[4]+a[5]);
	a[2] += a[7];
	for (int i=0; i<3; i++)
		a[i].x2n();
	c[10] = (a[0]*a[1])+(a[0]*a[2])+(a[1]*a[2]);
	c[10].relin();
	c[10].modSwitch();
	for (int i=0; i<3; i++)
		a[i].x2c();
	s[0] = a[0]+a[1]+a[2];
	lvl ++;
	// depth 2
	for (int i=0; i<21; i++)
		b[i].x2c();
	for (int i=0; i<7; i++)
		a[i] = b[3*i]+b[3*i+1]+b[3*i+2];
	for (int i=0; i<21; i++)
		b[i].x2n();
	for (int i=0; i<7; i++) {
		b[i] = (b[3*i]*b[3*i+1])+(b[3*i]*b[3*i+2])+(b[3*i+1]*c[3*i+2]);
		b[i].relin();
		b[i].modSwitch();
	}
	for (int i=0; i<3; i++) {
		for (int j=0; j<3; j++)
			c[3*i+j].x2c();
		a[i+7] = c[3*i]+c[3*i+1]+c[3*i+2];
		for (int j=0; j<3; j++)
			c[3*i+j].x2n();
		b[i+7] = (c[3*i]*c[3*i+1])+(c[3*i]*c[3*i+2])+(c[3*i+1]*c[3*i+2]);
		b[i+7].relin();
		b[i+7].modSwitch();
	}
	c[9].x2c();
	c[10].x2c();
	a[10] = c[9]+c[10];
	c[9].x2n();
	c[10].x2n();
	b[10] *= c[9];
	//////
	for (int i=0; i<3; i++) {
		for (int j=0; j<3; j++)
			a[3*i+j].x2n();
		b[i+11] = (a[3*i]*a[3*i+1])+(a[3*i]*a[3*i+2])+(a[3*i+1]*a[3*i+2]);
		b[i+11].relin();
		b[i+11].modSwitch();
		for (int j=0; j<3; j++)
			a[3*i+j].x2c();
		a[i] = a[3*i]+a[3*i+1]+a[3*i+2];
	}
	a[9].x2c();
	a[10].x2c();
	a[3] = a[9]+a[10];
	a[9].x2n();
	a[10].x2n();
	b[14] = a[9]*a[10];
	////
	a[0].x2n();
	a[1].x2n();
	b[15] = a[0]*a[1];
	b[15].relin();
	b[15].modSwitch();
	a[0].x2c();
	a[1].x2c();
	a[0] += a[1];

	a[2].x2n();
	a[3].x2n();
	b[16] = a[2]*a[3];
	b[16].relin();
	b[16].modSwitch();
	a[2].x2c();
	a[3].x2c();
	a[2] += a[3];
	////
	a[0].x2n();
	a[1].x2n();
	b[17] = a[0]*a[1];
	b[17].relin();
	b[17].modSwitch();
	s[1] = a[0]+a[1];
	lvl ++;

	// depth 3
	for (int i=0; i<18; i++)
		b[i].x2c();
	for (int i=0; i<6; i++)
		a[i] = b[3*i]+b[3*i+1]+b[3*i+2];
	for (int i=0; i<18; i++)
		b[i].x2n();
	for (int i=0; i<6; i++) {
		b[i] = (b[3*i]*b[3*i+1])+(b[3*i]*b[3*i+2])+(b[3*i+1]*b[3*i+2]);
		b[i].relin();
		b[i].modSwitch();
	}
	for (int i=0; i<3; i++)
		a[i].x2n();
	b[6] = (a[0]*a[1])+(a[0]*a[2])+(a[1]*a[2]);
	b[6].relin();
	b[6].modSwitch();
	for (int i=0; i<3; i++)
		a[i].x2c();
	a[0] += (a[1]+a[2]);
	for (int i=3; i<6; i++)
		a[i].x2n();
	b[7] = (a[3]*a[4])+(a[3]*a[5])+(a[4]*a[5]);
	b[7].relin();
	b[7].modSwitch();
	for (int i=3; i<6; i++)
		a[i].x2c();
	a[1] = a[3]+a[4]+a[5];
	a[0].x2n();
	a[1].x2n();
	b[8] = a[0]*a[1];
	b[8].relin();
	b[8].modSwitch();
	a[0].x2c();
	a[1].x2c();
	s[2] = a[0]+a[1];
	lvl ++;

	// depth 4
	for (int i=0; i<9; i++)
		b[i].x2c();
	for (int i=0; i<3; i++)
		a[i] = b[3*i]+b[3*i+1]+b[3*i+2];
	for (int i=0; i<9; i++)
		b[i].x2n();
	for (int i=0; i<3; i++) {
		b[i] = (b[3*i]*b[3*i+1])+(b[3*i]*b[3*i+2])+(b[3*i+1]*b[3*i+2]);
		b[i].relin();
		b[i].modSwitch();
	}
	for (int i=0; i<3; i++)
		a[i].x2n();
	b[3] = (a[0]*a[1])+(a[0]*a[2])+(a[1]*a[2]);
	b[3].relin();
	b[3].modSwitch();
	for (int i=0; i<3; i++)
		a[i].x2c();
	s[3] = a[0]+a[1]+a[2];
	lvl ++;

	// depth 5
	b[0].x2c();
	b[1].x2c();
	a[0] = b[0]+b[1];
	b[0].x2n();
	b[1].x2n();
	b[0] *= b[1];
	b[0].relin();
	b[0].modSwitch();
	b[2].x2c();
	b[3].x2c();
	a[1] = b[2]+b[3];
	b[2].x2n();
	b[3].x2n();
	b[1] = b[2]*b[3];
	b[1].relin();
	b[1].modSwitch();
	a[0].x2c();
	a[1].x2c();
	s[4] = a[0]+a[1];

	a[0].x2n();
	a[1].x2n();
	b[2] = a[0]*a[1];
	for (int i=0; i<3; i++)
		b[i].x2c();
	s[5] = b[0]+b[1]+b[2];
	s[5].relin();
	s[5].modSwitch();
	lvl ++;
	for (int i=0; i<5; i++)
		s[i].raiseToLevel(lvl);
	for (int i=5; i<8; i++)
		s[i].set(s[0].levelGet(), s[0].deviceGet(), s[0].domainGet());
}












