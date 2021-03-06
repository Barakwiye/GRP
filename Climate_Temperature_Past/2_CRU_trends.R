###############################################################################
# Calculates mean precipitation for GRP countries.
###############################################################################

source('../0_settings.R')

library(rgdal)
library(raster)
library(lubridate)
library(dplyr)
library(foreach)
library(doParallel)
library(spatial.tools)

n_cpus <- 3

cl  <- makeCluster(n_cpus)
registerDoParallel(cl)

product <- 'cru_ts3.22'
datestring <- '1901.2013'

# Note the below code is INCLUSIVE of the start date
cru_start_date <- as.Date('1901/1/1')
# Note the below code is EXCLUSIVE of the end date
cru_end_date <- as.Date('2014/1/1')

yrs <- seq(year(cru_start_date), year(cru_end_date))
dates <- seq(cru_start_date, cru_end_date, by='months')
dates <- dates[dates < cru_end_date]
num_periods <- 12

# Choose a start and end year for the data to include in this analysis
start_date <- as.Date('1984/1/1') # Inclusive
end_date <- as.Date('2014/1/1') # Exclusive

datasets <- c('tmn', 'tmx', 'tmp')

in_folder <- file.path(prefix, "GRP", "CRU")
out_folder <- file.path(prefix, "GRP", "CRU")
shp_folder <- file.path(prefix, "GRP", "Boundaries")
stopifnot(file_test('-d', in_folder))
stopifnot(file_test('-d', out_folder))
stopifnot(file_test('-d', shp_folder))

aoi_polygons <- readOGR(shp_folder, 'Analysis_Areas')
aoi_polygons <- aoi_polygons[aoi_polygons$Name == "Horn of Africa", ]

foreach (dataset=datasets, .inorder=FALSE,
         .packages=c("rgdal", "lubridate", "dplyr", "raster")) %:%
    foreach (n=1:nrow(aoi_polygons), .inorder=FALSE) %dopar% {
        aoi <- aoi_polygons[n, ]
        name <- as.character(aoi$Name)
        name <- gsub(' ', '', name)

        filename_base <- paste0(name, '_', product, '_', dataset, '_')
        cru_data_file <- file.path(out_folder,
                              paste0(filename_base, datestring,  '.tif'))

        # Calculate the band numbers that are needed
        included_dates <- dates[(dates >= start_date) & (dates < end_date)]
        band_nums <- c(1:length(dates))[(dates >= start_date) & (dates < end_date)]

        cru_data <- stack(cru_data_file, bands=band_nums)

        # Setup a dataframe with the precipitation data so anomalies, etc. can 
        # be calculated
        years <- year(included_dates)
        years_rep <- rep(years, each=nrow(cru_data)*ncol(cru_data))
        subyears <- rep(seq(1, num_periods),  length.out=nlayers(cru_data))
        subyears_rep <- rep(subyears, each=nrow(cru_data)*ncol(cru_data))
        pixels_rep <- rep(seq(1:(nrow(cru_data)*ncol(cru_data))), nlayers(cru_data))
        cru_data_df <- data.frame(year=years_rep,
                                  subyear=subyears_rep, 
                                  pixel=pixels_rep,
                                  cru_data=as.vector(cru_data))
        cru_data_df <- tbl_df(cru_data_df)

        get_slope <- function(data) {
            if (all(is.na(data$annual_data))) {
                d <- data.frame(c("(Intercept)", "year"), NA, NA)
            } else {
                model <- lm(annual_data ~ year, data=data)
                d <- data.frame(summary(model)$coefficients[, c(1, 4)])
                d <- cbind(row.names(d), d)
            }
            names(d) <- c('coef', 'estimate', 'p_val')
            row.names(d) <- NULL
            return(d)
        }
        if (dataset == "pet") {
            annual_lm_coefs <- group_by(cru_data_df, year, pixel) %>%
                summarize(annual_data=mean(cru_data, na.rm=TRUE)) %>%
                group_by(pixel) %>%
                do(get_slope(.))
        } else {
            annual_lm_coefs <- group_by(cru_data_df, year, pixel) %>%
                summarize(annual_data=mean(cru_data, na.rm=TRUE)) %>%
                group_by(pixel) %>%
                do(get_slope(.))
        }

        # Use cru_data raster as a template
        decadal_slope_rast <- brick(cru_data, values=FALSE, nl=1)
        decadal_slope_rast <- setValues(decadal_slope_rast,
                                   matrix(filter(annual_lm_coefs, coef == "year")$estimate * 10, 
                                          nrow=nrow(cru_data)*ncol(cru_data), 
                                          ncol=1, byrow=TRUE))
        decadal_slope_rast <- writeRaster(decadal_slope_rast,
                    filename=file.path(out_folder, paste0(filename_base, 
                                                          'decadal_slope.tif')), 
                    overwrite=TRUE)

        decadal_p_val_rast <- brick(cru_data, values=FALSE, nl=1)
        decadal_p_val_rast <- setValues(decadal_p_val_rast,
                                   matrix(filter(annual_lm_coefs, coef == "year")$p_val, 
                                          nrow=nrow(cru_data)*ncol(cru_data), 
                                          ncol=1, byrow=TRUE))
        decadal_p_val_rast <- writeRaster(decadal_p_val_rast,
                    filename=file.path(out_folder, paste0(filename_base, 
                                                          'decadal_pval.tif')), 
                    overwrite=TRUE)

        decadal_slope_rast <- overlay(decadal_slope_rast, decadal_p_val_rast,
            fun=function(slp, p) {
                slp[p > .05] <- NA
                return(slp)
            },
            filename=file.path(out_folder, paste0(filename_base, 
                                                  'decadal_slope_masked.tif')),
            overwrite=TRUE)

}

stopCluster(cl)
