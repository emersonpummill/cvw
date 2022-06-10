#!/usr/bin/python3
# Madeleine Masser-Frye mmasserfrye@hmc.edu 5/22

import scipy.optimize as opt
import subprocess
import csv
import re
from matplotlib.cbook import flatten
import matplotlib.pyplot as plt
import matplotlib.lines as lines
import numpy as np
from collections import namedtuple
import sklearn.metrics as skm

def synthsfromcsv(filename):
    Synth = namedtuple("Synth", "module tech width freq delay area lpower denergy")
    with open(filename, newline='') as csvfile:
        csvreader = csv.reader(csvfile)
        global allSynths
        allSynths = list(csvreader)[1:]
        for i in range(len(allSynths)):
            for j in range(len(allSynths[0])):
                try: allSynths[i][j] = int(allSynths[i][j])
                except: 
                    try: allSynths[i][j] = float(allSynths[i][j])
                    except: pass
            allSynths[i] = Synth(*allSynths[i])
    return allSynths
    
def synthsintocsv():
    ''' writes a CSV with one line for every available synthesis
        each line contains the module, tech, width, target freq, and resulting metrics
    '''
    print("This takes a moment...")
    bashCommand = "find . -path '*runs/ppa*rv32e*' -prune"
    output = subprocess.check_output(['bash','-c', bashCommand])
    allSynths = output.decode("utf-8").split('\n')[:-1]

    specReg = re.compile('[a-zA-Z0-9]+')
    metricReg = re.compile('-?\d+\.\d+[e]?[-+]?\d*')

    file = open("ppaData.csv", "w")
    writer = csv.writer(file)
    writer.writerow(['Module', 'Tech', 'Width', 'Target Freq', 'Delay', 'Area', 'L Power (nW)', 'D energy (fJ)'])

    for oneSynth in allSynths:
        module, width, risc, tech, freq = specReg.findall(oneSynth)[2:7]
        tech = tech[:-2]
        metrics = []
        for phrase in [['Path Slack', 'qor'], ['Design Area', 'qor'], ['100', 'power']]:
            bashCommand = 'grep "{}" '+ oneSynth[2:]+'/reports/*{}*'
            bashCommand = bashCommand.format(*phrase)
            try: output = subprocess.check_output(['bash','-c', bashCommand])
            except: 
                print(module + width + tech + freq + " doesn't have reports")
                print("Consider running cleanup() first")
            nums = metricReg.findall(str(output))
            nums = [float(m) for m in nums]
            metrics += nums
        delay = 1000/int(freq) - metrics[0]
        area = metrics[1]
        lpower = metrics[4]
        denergy = (metrics[2] + metrics[3])*delay*1000 # (switching + internal powers)*delay, more practical units for regression coefs

        if ('flop' in module): # since two flops in each module 
            [area, lpower, denergy] = [n/2 for n in [area, lpower, denergy]] 

        writer.writerow([module, tech, width, freq, delay, area, lpower, denergy])
    file.close()

def cleanup():
    ''' removes runs that didn't work
    '''
    bashCommand = 'grep -r "Error" runs/ppa*/reports/*qor*'
    try: 
        output = subprocess.check_output(['bash','-c', bashCommand])
        allSynths = output.decode("utf-8").split('\n')[:-1]
        for run in allSynths:
            run = run.split('MHz')[0]
            bc = 'rm -r '+ run + '*'
            output = subprocess.check_output(['bash','-c', bc])
    except: pass

    bashCommand = "find . -path '*runs/ppa*rv32e*' -prune"
    output = subprocess.check_output(['bash','-c', bashCommand])
    allSynths = output.decode("utf-8").split('\n')[:-1]
    for oneSynth in allSynths:
        for phrase in [['Path Length', 'qor'], ['Design Area', 'qor'], ['100', 'power']]:
            bashCommand = 'grep "{}" '+ oneSynth[2:]+'/reports/*{}*'
            bashCommand = bashCommand.format(*phrase)
            try: output = subprocess.check_output(['bash','-c', bashCommand])
            except: 
                bc = 'rm -r '+ oneSynth[2:]
                try: output = subprocess.check_output(['bash','-c', bc])
                except: pass
    print("All cleaned up!")

def getVals(tech, module, var, freq=None):
    ''' for a specified tech, module, and variable/metric
        returns a list of values for that metric in ascending width order
        works at a specified target frequency or if none is given, uses the synthesis with the best achievable delay for each width
    '''

    metric = []
    widthL = []

    if (freq != None):
        for oneSynth in allSynths:
            if (oneSynth.freq == freq) & (oneSynth.tech == tech) & (oneSynth.module == module):
                widthL += [oneSynth.width]
                osdict = oneSynth._asdict()
                metric += [osdict[var]]
        metric = [x for _, x in sorted(zip(widthL, metric))] # ordering
    else:
        for w in widths:
            for oneSynth in bestSynths:
                if (oneSynth.width == w) & (oneSynth.tech == tech) & (oneSynth.module == module):
                    osdict = oneSynth._asdict()
                    met = osdict[var]
                    metric += [met]
    return metric

def csvOfBest():
    bestSynths = []
    for tech in [x.tech for x in techSpecs]:
        for mod in modules:
            for w in widths:
                m = np.Inf # large number to start
                best = None
                if [mod, tech, w] in leftblue:
                    for oneSynth in allSynths:
                        if (oneSynth.width == w) & (oneSynth.tech == tech) & (oneSynth.module == mod):
                            if (oneSynth.freq < m) & (1000/oneSynth.delay < oneSynth.freq):
                                if ([mod, tech, w] != ['mux2', 'sky90', 128]) or (oneSynth.area < 1100):
                                    m = oneSynth.freq
                                    best = oneSynth
                else:
                    for oneSynth in allSynths:
                        if (oneSynth.width == w) & (oneSynth.tech == tech) & (oneSynth.module == mod):
                            if (oneSynth.delay < m) & (1000/oneSynth.delay > oneSynth.freq): 
                                m = oneSynth.delay
                                best = oneSynth
                if (best != None) & (best not in bestSynths):
                    bestSynths += [best]

    file = open("bestSynths.csv", "w")
    writer = csv.writer(file)
    writer.writerow(['Module', 'Tech', 'Width', 'Target Freq', 'Delay', 'Area', 'L Power (nW)', 'D energy (fJ)'])
    for synth in bestSynths:
        writer.writerow(list(synth))
    file.close()
    return bestSynths
    
def genLegend(fits, coefs, r2, spec, ale=False):
    ''' generates a list of two legend elements 
        labels line with fit equation and dots with tech and r squared of the fit
    '''

    coefsr = [str(round(c, 3)) for c in coefs]

    eq = ''
    ind = 0

    eqDict = {'c': '', 'l': 'N', 's': '$N^2$', 'g': '$log_2$(N)', 'n': 'N$log_2$(N)'}
    if ale:
        if (normAddWidth == 32):
            eqDict = {'c': '', 'l': '(N/32)', 's': '$(N/32)^2$', 'g': '$log_2$(N/32)', 'n': '(N/32)$log_2$(N/32)'}
        elif normAddWidth != 1:
            print('Legend equations are wrong')

    for k in eqDict.keys():
        if k in fits:
            if str(coefsr[ind]) != '0.0': eq += " + " + coefsr[ind] + eqDict[k]
            ind += 1

    eq = eq[3:] # chop off leading ' + '

    legend_elements = [lines.Line2D([0], [0], color=spec.color, label=eq)]
    legend_elements += [lines.Line2D([0], [0], color=spec.color, ls='', marker=spec.shape, label=spec.tech +'  $R^2$='+ str(round(r2, 4)))]
    return legend_elements

def oneMetricPlot(module, var, freq=None, ax=None, fits='clsgn', norm=True, color=None):
    ''' module: string module name
        freq: int freq (MHz)
        var: string delay, area, lpower, or denergy
        fits: constant, linear, square, log2, Nlog2
        plots given variable vs width for all matching syntheses with regression
    '''
    singlePlot = True
    if ax or (freq == 10):
        singlePlot = False
    if ax is None:
        ax = plt.gca()

    fullLeg = []
    allWidths = []
    allMetrics = []

    ale = (var != 'delay') # if not delay, must be area, leakage, or energy
    modFit = fitDict[mod]
    fits = modFit[ale]

    for spec in techSpecs:
        metric = getVals(spec.tech, module, var, freq=freq)
        
        if norm:
            techdict = spec._asdict()
            norm = techdict[var]
            metric = [m/norm for m in metric]

        if len(metric) == 5: # don't include the spec if we don't have points for all widths
            xp, pred, coefs, r2 = regress(widths, metric, fits)
            fullLeg += genLegend(fits, coefs, r2, spec, ale=ale)
            c = color if color else spec.color
            ax.scatter(widths, metric, color=c, marker=spec.shape)
            ax.plot(xp, pred, color=c)
            allWidths += widths
            allMetrics += metric

    combined = TechSpec('combined', 'red', '_', 0, 0, 0, 0)
    xp, pred, coefs, r2 = regress(allWidths, allMetrics, fits)
    leg = genLegend(fits, coefs, r2, combined, ale=ale)
    fullLeg += leg
    ax.plot(xp, pred, color='red')

    if norm:
        ylabeldic = {"lpower": "Leakage Power (add32)", "denergy": "Energy/Op (add32)", "area": "Area (add32)", "delay": "Delay (FO4)"}
    else:
        ylabeldic = {"lpower": "Leakage Power (nW)", "denergy": "Dynamic Energy (fJ)", "area": "Area (sq microns)", "delay": "Delay (ns)"}

    ax.legend(handles=fullLeg)
    ax.set_xticks(widths)
    ax.set_xlabel("Width (bits)")
    ax.set_ylabel(ylabeldic[var])

    if (module in ['flop', 'csa']) & (var == 'delay'):
        ax.set_ylim(ymin=0)
        ytop = ax.get_ylim()[1]
        ax.set_ylim(ymax=1.1*ytop)

    if singlePlot:
        titleStr = "  (target  " + str(freq)+ "MHz)" if freq != None else " (best achievable delay)"
        ax.set_title(module + titleStr)
        plt.savefig('./plots/PPA/'+ module + '_' + var + '.png')
        # plt.show()
    return fullLeg

def regress(widths, var, fits='clsgn'):
    ''' fits a curve to the given points
        returns lists of x and y values to plot that curve and legend elements with the equation
    '''

    funcArr = genFuncs(fits)
    widths = [w/normAddWidth for w in widths]

    mat = []
    for w in widths:
        row = []
        for func in funcArr:
            row += [func(w)]
        mat += [row]
    
    y = np.array(var, dtype=np.float)
    coefs = opt.nnls(mat, y)[0]
    yp = []
    for w in widths:
        n = [func(w) for func in funcArr]
        yp += [sum(np.multiply(coefs, n))]
    r2 = skm.r2_score(y, yp)

    xp = np.linspace(4, 140, 200)
    pred = []
    for x in xp:
        n = [func(x/normAddWidth) for func in funcArr]
        pred += [sum(np.multiply(coefs, n))]

    return xp, pred, coefs, r2

def makeCoefTable():
    ''' 
        writes CSV with each line containing the coefficients for a regression fit 
        to a particular combination of module, metric (including both techs, normalized)
    '''
    file = open("ppaFitting.csv", "w")
    writer = csv.writer(file)
    writer.writerow(['Module', 'Metric', '1', 'N', 'N^2', 'log2(N)', 'Nlog2(N)', 'R^2'])

    for module in modules:
        for var in ['delay', 'area', 'lpower', 'denergy']:
            ale = (var != 'delay')
            metL = []
            modFit = fitDict[module]
            fits = modFit[ale]

            for spec in techSpecs:
                metric = getVals(spec.tech, module, var)
                techdict = spec._asdict()
                norm = techdict[var]
                metL += [m/norm for m in metric]

            xp, pred, coefs, r2 = regress(widths*2, metL, fits)
            coefs = np.ndarray.tolist(coefs)
            coefsToWrite  = [None]*5
            fitTerms = 'clsgn'
            ind = 0
            for i in range(len(fitTerms)):
                if fitTerms[i] in fits:
                    coefsToWrite[i] = coefs[ind]
                    ind += 1
            row = [module, var] + coefsToWrite + [r2]
            writer.writerow(row)

    file.close()

def genFuncs(fits='clsgn'):
    ''' helper function for regress()
        returns array of functions with one for each term desired in the regression fit
    '''
    funcArr = []
    if 'c' in fits:
        funcArr += [lambda x: 1]
    if 'l' in fits:
        funcArr += [lambda x: x]
    if 's' in fits:
        funcArr += [lambda x: x**2]
    if 'g' in fits:
        funcArr += [lambda x: np.log2(x)]
    if 'n' in fits:
        funcArr += [lambda x: x*np.log2(x)]
    return funcArr

def noOutliers(median, freqs, delays, areas):
    ''' returns a pared down list of freqs, delays, and areas 
        cuts out any syntheses in which target freq isn't within 75% of the min delay target to focus on interesting area
        helper function to freqPlot()
    '''
    f=[]
    d=[]
    a=[]
    for i in range(len(freqs)):
        norm = freqs[i]/median
        if (norm > 0.4) & (norm<1.4):
            f += [freqs[i]]
            d += [delays[i]]
            a += [areas[i]]
    
    return f, d, a

def freqPlot(tech, mod, width):
    ''' plots delay, area, area*delay, and area*delay^2 for syntheses with specified tech, module, width
    '''

    freqsL, delaysL, areasL = ([[], []] for i in range(3))
    for oneSynth in allSynths:
        if (mod == oneSynth.module) & (width == oneSynth.width) & (tech == oneSynth.tech):
            ind = (1000/oneSynth.delay < oneSynth.freq) # when delay is within target clock period
            freqsL[ind] += [oneSynth.freq]
            delaysL[ind] += [oneSynth.delay]
            areasL[ind] += [oneSynth.area]

    median = np.median(list(flatten(freqsL)))
    
    f, (ax1, ax2) = plt.subplots(2, 1, sharex=True)
    for ax in (ax1, ax2): #, ax3, ax4):
        ax.ticklabel_format(useOffset=False, style='plain')

    for ind in [0,1]:
        areas = areasL[ind]
        delays = delaysL[ind]
        freqs = freqsL[ind]

        freqs, delays, areas = noOutliers(median, freqs, delays, areas) # comment out to see all syntheses

        c = 'blue' if ind else 'green'
        # adprod = adprodpow(areas, delays, 1)
        # adpow = adprodpow(areas, delays, 2)
        ax1.scatter(freqs, delays, color=c)
        ax2.scatter(freqs, areas, color=c)
        # ax3.scatter(freqs, adprod, color=c)
        # ax4.scatter(freqs, adpow, color=c)

    legend_elements = [lines.Line2D([0], [0], color='green', ls='', marker='o', label='timing achieved'),
                       lines.Line2D([0], [0], color='blue', ls='', marker='o', label='slack violated')]

    ax1.legend(handles=legend_elements)
    
    ax2.set_xlabel("Target Freq (MHz)")
    ax1.set_ylabel('Delay (ns)')
    ax2.set_ylabel('Area (sq microns)')
    # ax3.set_ylabel('Area * Delay')
    # ax4.set_ylabel('Area * $Delay^2$')
    ax1.set_title(mod + '_' + str(width))
    plt.savefig('./plots/freqBuckshot/' + tech + '/' + mod + '/' + str(width) + '.png')
    # plt.show()

def squareAreaDelay(tech, mod, width):
    ''' plots delay, area, area*delay, and area*delay^2 for syntheses with specified tech, module, width
    '''
    global allSynths
    freqsL, delaysL, areasL = ([[], []] for i in range(3))
    for oneSynth in allSynths:
        if (mod == oneSynth.module) & (width == oneSynth.width) & (tech == oneSynth.tech):
            ind = (1000/oneSynth.delay < oneSynth.freq) # when delay is within target clock period
            freqsL[ind] += [oneSynth.freq]
            delaysL[ind] += [oneSynth.delay]
            areasL[ind] += [oneSynth.area]

    f, (ax1) = plt.subplots(1, 1)
    ax2 = ax1.twinx()

    for ind in [0,1]:
        areas = areasL[ind]
        delays = delaysL[ind]
        targets = freqsL[ind]
        targets = [1000/f for f in targets]
        
        targets, delays, areas = noOutliers(targets, delays, areas) # comment out to see all 
        
        if not ind:
            achievedDelays = delays

        c = 'blue' if ind else 'green'
        ax1.scatter(targets, delays, marker='^', color=c)
        ax2.scatter(targets, areas, marker='s', color=c)
    
    bestAchieved = min(achievedDelays)
        
    legend_elements = [lines.Line2D([0], [0], color='green', ls='', marker='^', label='delay (timing achieved)'),
                       lines.Line2D([0], [0], color='green', ls='', marker='s', label='area (timing achieved)'),
                       lines.Line2D([0], [0], color='blue', ls='', marker='^', label='delay (timing violated)'),
                       lines.Line2D([0], [0], color='blue', ls='', marker='s', label='area (timing violated)')]

    ax2.legend(handles=legend_elements, loc='upper left')
    
    ax1.set_xlabel("Delay Targeted (ns)")
    ax1.set_ylabel("Delay Achieved (ns)")
    ax2.set_ylabel('Area (sq microns)')
    ax1.set_title(mod + '_' + str(width))

    squarify(f)

    xvals = np.array(ax1.get_xlim())
    frac = (min(flatten(delaysL))-xvals[0])/(xvals[1]-xvals[0])
    areaLowerLim = min(flatten(areasL))-100
    areaUpperLim = max(flatten(areasL))/frac + areaLowerLim
    ax2.set_ylim([areaLowerLim, areaUpperLim])
    ax1.plot(xvals, xvals, ls="--", c=".3")
    ax1.hlines(y=bestAchieved, xmin=xvals[0], xmax=xvals[1], color="black", ls='--')

    plt.savefig('./plots/squareareadelay_' + mod + '_' + str(width) + '.png')
    # plt.show()

def squarify(fig):
    ''' helper function for squareAreaDelay()
        forces matplotlib figure to be a square
    '''
    w, h = fig.get_size_inches()
    if w > h:
        t = fig.subplotpars.top
        b = fig.subplotpars.bottom
        axs = h*(t-b)
        l = (1.-axs/w)/2
        fig.subplots_adjust(left=l, right=1-l)
    else:
        t = fig.subplotpars.right
        b = fig.subplotpars.left
        axs = w*(t-b)
        l = (1.-axs/h)/2
        fig.subplots_adjust(bottom=l, top=1-l)

def adprodpow(areas, delays, pow):
    ''' for each value in [areas] returns area*delay^pow
        helper function for freqPlot'''
    result = []

    for i in range(len(areas)):
        result += [(areas[i])*(delays[i])**pow]
    
    return result

def plotPPA(mod, freq=None, norm=True, aleOpt=False):
    ''' for the module specified, plots width vs delay, area, leakage power, and dynamic energy with fits
        if no freq specified, uses the synthesis with best achievable delay for each width
        overlays data from both techs
    '''
    plt.rcParams["figure.figsize"] = (10,7)
    fig, axs = plt.subplots(2, 2)
    # fig, axs = plt.subplots(4, 1)

    # oneMetricPlot(mod, 'delay', ax=axs[0], fits=modFit[0], freq=freq, norm=norm)
    # oneMetricPlot(mod, 'area', ax=axs[1], fits=modFit[1], freq=freq, norm=norm)
    # oneMetricPlot(mod, 'lpower', ax=axs[2], fits=modFit[1], freq=freq, norm=norm)
    # oneMetricPlot(mod, 'denergy', ax=axs[3], fits=modFit[1], freq=freq, norm=norm)
    oneMetricPlot(mod, 'delay', ax=axs[0,0], freq=freq, norm=norm)
    oneMetricPlot(mod, 'area', ax=axs[0,1], freq=freq, norm=norm)
    oneMetricPlot(mod, 'lpower', ax=axs[1,0], freq=freq, norm=norm)
    fullLeg = oneMetricPlot(mod, 'denergy', ax=axs[1,1], freq=freq, norm=norm)
    
    if aleOpt:
        oneMetricPlot(mod, 'area', ax=axs[0,1], freq=10, norm=norm, color='black')
        oneMetricPlot(mod, 'lpower', ax=axs[1,0], freq=10, norm=norm, color='black')
        oneMetricPlot(mod, 'denergy', ax=axs[1,1], freq=10, norm=norm, color='black')
    
    titleStr = "  (target  " + str(freq)+ "MHz)" if freq != None else " (best achievable delay)"
    n = 'normalized' if norm else 'unnormalized'
    saveStr = './plots/PPA/'+ n + '/' + mod + '.png'
    plt.suptitle(mod + titleStr)

    # fig.legend(handles=fullLeg, ncol=3, loc='center', bbox_to_anchor=(0.3, 0.82, 0.4, 0.2))

    if freq != 10: plt.savefig(saveStr)
    # plt.show()

def plotBestAreas(mod):
    fig, axs = plt.subplots(1, 1)
    ### all areas on one
    # mods = ['priorityencoder', 'add', 'csa', 'shiftleft', 'comparator', 'flop']
    # colors = ['red', 'orange', 'yellow', 'green', 'blue', 'purple']
    # legend_elements = []
    # for i in range(len(mods)):
    #     oneMetricPlot(mods[i], 'area', ax=axs, freq=10, norm=False, color=colors[i])
    #     legend_elements += [lines.Line2D([0], [0], color=colors[i], ls='', marker='o', label=mods[i])]
    # plt.suptitle('Optimized Areas (target freq 10MHz)')
    # plt.legend(handles=legend_elements)
    # plt.savefig('./plots/bestareas.png')
    # plt.show()

    oneMetricPlot(mod, 'area', freq=10)
    plt.title(mod + ' Optimized Areas (target freq 10MHz)')
    plt.savefig('./plots/bestAreas/' + mod + '.png')
    
if __name__ == '__main__':
    ##############################
    # set up stuff, global variables
    widths = [8, 16, 32, 64, 128]
    modules = ['priorityencoder', 'add', 'csa', 'shiftleft', 'comparator', 'flop', 'mux2', 'mux4', 'mux8', 'mult']
    normAddWidth = 32 # divisor to use with N since normalizing to add_32

    fitDict = {'add': ['cg', 'l', 'l'], 'mult': ['cg', 's', 'ls'], 'comparator': ['cg', 'l', 'l'], 'csa': ['c', 'l', 'l'], 'shiftleft': ['cg', 'l', 'ln'], 'flop': ['c', 'l', 'l'], 'priorityencoder': ['cg', 'l', 'l']}
    fitDict.update(dict.fromkeys(['mux2', 'mux4', 'mux8'], ['cg', 'l', 'l']))
    leftblue = [['mux2', 'sky90', 32], ['mux2', 'sky90', 64], ['mux2', 'sky90', 128], ['mux8', 'sky90', 32], ['mux2', 'tsmc28', 8], ['mux2', 'tsmc28', 64]] 

    TechSpec = namedtuple("TechSpec", "tech color shape delay area lpower denergy")
    techSpecs = [['sky90', 'green', 'o', 43.2e-3, 1330.84, 582.81, 520.66],  ['tsmc28', 'blue', '^', 12.2e-3, 209.29, 1060, 81.43]]
    techSpecs = [TechSpec(*t) for t in techSpecs]
    # invz1arealeakage = [['sky90', 1.96, 1.98], ['gf32', .351, .3116], ['tsmc28', .252, 1.09]] #['gf32', 'purple', 's', 15e-3]
    ##############################

    # cleanup() # run to remove garbage synth runs
    # synthsintocsv() # slow, run only when new synth runs to add to csv
  
    allSynths = synthsfromcsv('ppaData.csv') # your csv here!
    bestSynths = csvOfBest()

    # ### plotting examples
    # squareAreaDelay('sky90', 'add', 32)
    # oneMetricPlot('add', 'delay')
    # freqPlot('sky90', 'mux4', 16)
    # makeCoefTable()
    
    for mod in ['mux2']: #modules:
        plotPPA(mod, norm=False)
        plotPPA(mod) #, aleOpt=True)
        # plotBestAreas(mod)
        # for w in [8, 16, 32, 64, 128]:
        #     freqPlot('sky90', mod, w)
        #     freqPlot('tsmc28', mod, w)
        plt.close('all')