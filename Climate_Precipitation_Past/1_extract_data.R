###############################################################################
# Crops CHIRPS pentad or monthly precipitation data to cover the spatial extent 
# of each site.
###############################################################################

source('../0_settings.R')

library(rgdal)
library(raster)
library(stringr)
library(gdalUtils)
library(rgeos)
library(teamlucc)
library(foreach)
library(doParallel)

warp_threads <- 4

cl  <- makeCluster(3)
registerDoParallel(cl)

#dataset <- 'pentad'
dataset <- 'monthly'

in_folder <- file.path(prefix, "CHIRPS-2.0", paste0('global-', dataset))
out_folder <- file.path(prefix, "GRP", "CHIRPS-2.0")
shp_folder <- file.path(prefix, "GRP", "Boundaries")
stopifnot(file_test('-d', in_folder))
stopifnot(file_test('-d', out_folder))
stopifnot(file_test("-d", shp_folder))

tifs <- dir(in_folder, pattern='.tif$')

datestrings <- gsub('.tif', '', (str_extract(tifs, '[0-9]{4}\\.[0-9]{2}.tif$')))
years <- as.numeric(str_extract(datestrings, '^[0-9]{4}'))
# The subyears strings are numeric codes referring to either pentads or months, 
# depending on the dataset chosen.
subyears <- as.numeric(str_extract(datestrings, '[0-9]{2}$'))

datestrings <- datestrings[order(years, subyears)]
tifs <- tifs[order(years, subyears)]

datestrings <- gsub('[.]', '', datestrings)
start_date <- datestrings[1]
end_date <- datestrings[length(datestrings)]

# Build a VRT with all dates in a single layer stacked VRT file (this stacks 
# the tifs, but with delayed computation - the actual cropping and stacking 
# computations won't take place until the gdalwarp line below that is run for 
# each aoi)
vrt_file <- extension(rasterTmpFile(), 'vrt')
gdalbuildvrt(file.path(in_folder, tifs), vrt_file, separate=TRUE, 
             overwrite=TRUE)

# This is the projection of the CHIRPS files, read from the .hdr files 
# accompanying the data
s_srs <- '+proj=longlat +ellps=WGS84 +datum=WGS84 +no_defs +towgs84=0,0,0'

aoi_polygons <- readOGR(shp_folder, 'Analysis_Areas')

foreach (n=1:nrow(aoi_polygons), .inorder=FALSE,
         .packages=c('raster', 'teamlucc', 'rgeos', 'gdalUtils',
                     'rgdal')) %dopar% {
    timestamp()

    aoi <- aoi_polygons[n, ]
    name <- as.character(aoi$Name)
    name <- gsub(' ', '', name)
    aoi <- gConvexHull(aoi)
    aoi <- spTransform(aoi, CRS(utm_zone(aoi, proj4string=TRUE)))
    aoi <- gBuffer(aoi, width=100000)
    aoi <- spTransform(aoi, CRS(s_srs))
    te <- as.numeric(bbox(aoi))

    print(paste0("Processing ", name, "..."))

    # Round extent so that pixels are aligned properly
    te <- round(te * 20) / 20

    base_name <- file.path(out_folder,
                           paste0(name, '_CHIRPS_', dataset,
                                  '_', start_date, '-', end_date))

    chirps_tif <- paste0(base_name, '.tif')

    chirps <- gdalwarp(vrt_file, chirps_tif, s_srs=s_srs, te=te, multi=TRUE, 
                       wo=paste0("NUM_THREADS=", warp_threads), overwrite=TRUE, 
                       output_Raster=TRUE)

    ## Below is not needed with latest TIFs - they appear not to have an NA 
    ## code
    # chirps_NA_value <- -9999
    # chirps_tif_masked <- paste0(base_name, '_NAs_masked.tif')
    # chirps <- calc(chirps, function(vals) {
    #         vals[vals == chirps_NA_value] <- NA
    #         return(vals)
    #     }, filename=chirps_tif_masked, overwrite=TRUE)

    return(TRUE)
}

stopCluster(cl)
