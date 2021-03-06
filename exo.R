

# Importation  des packages



library(utils)
library(fs)
library(tidyverse)
library(stars)
library(raster)
library(sp)
library(gstat)
library(rgdal)
library(viridis)
library(viridisLite)

# Importation et traitement des donnees 
##Les donnees portent sur des rasters de la temperature à 5m  de resolution , ils sont été acquis au niveau de la platform  wordclim



##  Importons les data
climate_data<-utils::unzip(here::here("wc2.1_5m_tavg.zip"))
climate_data <- fs::dir_info(here::here())%>%dplyr::select(path)%>%filter(str_detect(path,"tif$"))%>%dplyr::pull()
## Stack  all raster occuring inth

climate_data <- raster::stack(climate_data)

print(climate_data)
## Procedons à une reprojection des differents rastres 

## Un petit apercu sur le nombe de raster et la taille et l'etendu des rasters
raster::nlayers(climate_data)
raster::extent(climate_data)
## La temperature parmois au senegal
month <- c("Jan", "Feb", "Mar", "Apr", "May", "Jun", 
           "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
## Changeons le noms des rasters regroupés
names(climate_data) <- month




#Importons les limites administratives du senegal


## Limite administratve du senegal
sene <- raster::getData('GADM', country='SN', level=0)


#Afficher les rasters  sur uniquement l'etendu du territoire senegalais


## Decoupons les rasters regroupés en fonction de la limite administrative du senegal
raster_red <- climate_data%>%crop(.,sene)
## Mask les NA 
ras_mask<-raster_red%>%mask(.,sene,na.rm=TRUE)
## Representation graphique de la carte
plot(ras_mask)


##Determinons pour chaque departement la temperature moyenne


## Chargeons le fichiers shapefile du departement et detremination des centroides par departement 
dep <- st_read(here::here("departement.shp"))%>%st_centroid()%>%st_transform(.,4326)%>%dplyr::select(geometry,NOM)
## departement et les centroides
departement_sene <- st_read(here::here("departement.shp"))
departement_sene%>%st_geometry()%>%plot()


##Extraction des temp en foction des centroides des differents departements crees


## Extraction
new<-raster::extract(climate_data,dep,sp=1,method="simple")

## Transformons enew en dataframe et renommons les colonnes contenant comme variables les coordonnees 
new_dataf<-as.data.frame(new)%>%dplyr::rename(lon=coords.x1,lat=coords.x2)%>%dplyr::select(lon,lat,everything())
## Petit apercu sur les differents 
glimpse(new_dataf)
## transformons l'architurede notre data frame 
temp<-new_dataf%>%pivot_longer(4:15,names_to="Mois",values_to="Temperature")
## Apercu sur nouveau data set cree
glimpse(temp)

##Determination des 10 dep les plus chaud en moyenne Departement 

## Moyenne des temperatures par departemens et determiners les 10 departements les plus chauds
data_inter <- temp%>%group_by(NOM)%>%summarise(mean=mean(Temperature))%>%as_tibble()%>%arrange(desc(mean))%>%dplyr::ungroup()
slice_head(data_inter,n=3)
## Ajoutons les coordonnes lon et lat
data_inter<-data_inter%>%dplyr::bind_cols(dplyr::select(new_dataf,c(lon,lat)))

# Interpolation : IDW et Kriging

##Toilettage du dataset pour realiser des interpolations et determination de la grille d'interpolation


## Transformons la limite du senegal en raster pour obtenir les grille d'interpolation
seene_ras <- sene%>%st_as_sf(.,st_crs(4326))%>%st_geometry()%>%as(.,"Spatial")%>%rasterize(.,climate_data$Feb)
## data frame avec les pixel present sur seene_ras
tempD <- data.frame(cellNos = seq(1:ncell(seene_ras)))
tempD$vals <- getValues(seene_ras)
## Supprimer les NA observations
tempD <- tempD[complete.cases(tempD), ]
### Vecteur contenant les pixels
cellNos <- c(tempD$cellNos)
## grille d'interpolation
gXY <- data.frame(xyFromCell(seene_ras, cellNos, spatial = FALSE))
## Apercu
glimpse(gXY)
## Assignons un nom bom pour la grille afin de l'utiliser pour le kriging
bon_gXY<-gXY
head(gXY)%>%data.table::data.table()


# Inverse Distance Weighted

##Les 10 departements ou il fait le plus chaud au senegal

inter <- data_inter%>%dplyr::select(lon,lat,everything())%>%sf::st_as_sf(.,crs=4326,coords=c("lon","lat"))%>%as(.,"Spatial")%>%as.data.frame()%>%mutate(across(2,round,0))
names(inter)[3:4] <- c("x", "y")

head(inter)%>%DT::datatable()

## Inverse  distance Weighted
IDW.pred <- idw(inter$mean ~ 1, locations = ~x+ y,
                data = inter, newdata = gXY, idp = 2)
ex<-IDW.pred%>%stars::st_as_stars()


##Creation d'un raster par la methode d'interpolation IDW

ggplot() + geom_stars(data =ex ) +
  coord_equal() +
  ##theme_void() +
  scale_fill_viridis() +
  scale_x_discrete(expand=c(0,0))+
  scale_y_discrete(expand=c(0,0))+labs(fill="Temperature ²C ",title = "IDW Interpolation de la temperature moyenne")


# Kriging

##Preparation de la grille et conversion de la projection en epsg 

## transformation de dataframe en spatial dataframe
coordinates(gXY)<-~x+y
## reprrojection
proj4string(gXY) <- CRS("+init=epsg:4326")
gXY<-spTransform(gXY,CRS("+init=epsg:31028"))
gXY<-gXY%>%as.data.frame()
## Reprojection dataset avec la temperature
coordinates(inter)<-~x+y
proj4string(inter) <- CRS("+init=epsg:4326")
inter_tran<-spTransform(inter,CRS("+init=epsg:31028"))
inter_tran <- inter_tran%>%as.data.frame()


#Determination du variogram

## Variogram
vgm1 <- variogram(mean ~ 1, ~x +y, inter_tran, cutoff = 800000, width = 3000)
##parametres
mod <- vgm(psill=14, "Exp", 25000, 1)
model_1 <- fit.variogram(vgm1, mod)
model_1
## Representation graphique
plot(vgm1, model = model_1)
## Krigeage 
krig.pred <- krige(inter_tran$mean ~ 1, locations = ~x + y,
                   data = inter_tran, newdata = gXY, model = model_1)


#Determination des rasters

bon_gXY$pred<-krig.pred$var1.pred
bon_gXY$var <- krig.pred$var1.var

kr.raster.p <- rasterFromXYZ(as.data.frame(bon_gXY[, 1:3]))
kr.raster.var <- rasterFromXYZ(as.data.frame(bon_gXY[, c(1:2,4)]))

plot(kr.raster.p,main="ordinary Kriging predictions")




plot(kr.raster.var,main="ordinary Kriging variance")


